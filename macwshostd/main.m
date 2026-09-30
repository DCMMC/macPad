// macwshostd — root-side, typed control plane for the native iPadOS host.
//
// This service intentionally exposes no shell strings and no arbitrary paths.
// Every request maps to a fixed operation and fixed argv/path allowlist.  The
// existing macos_gui.sh remains the single source of truth for chroot repair,
// GUI lifecycle, and crash-loop protection.

@import Foundation;
@import Darwin;

#include <dispatch/dispatch.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <pwd.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <xpc/xpc.h>
#include <mach/mach_time.h>
#include <mach/task.h>
#include <notify.h>

// Use the repository's one canonical protocol directory explicitly. Device
// source sync is deliberately non-destructive, so an old device-only header
// left beside main.m must never shadow a newly synchronized protocol through
// quoted-include search order.
#include "../include/macws_control_protocol.h"
#include "../include/macws_file_copy.h"
#include "../include/macws_host_protocol.h"
#include "../include/macws_steam_mach_rendezvous_protocol.h"
#include "../include/macws_steam_semaphore_protocol.h"
#include "../include/macws_stream_protocol.h"
#include "../include/macws_settings_bridge_notify.h"
#include "../include/macws_power_lifecycle.h"

extern char **environ;

// Darwin's public spawn.h does not expose this Apple-private declaration,
// although libsystem has shipped it since iOS 6.  XNU 8792 maps process type
// 0x100 to TASK_APPTYPE_APP_DEFAULT.  macOS AppKit's concurrent scrolling
// creates a CA_CLIENT work interval; the iOS kernel deliberately rejects that
// work-interval type with KERN_NOT_SUPPORTED when task_is_app() is false.
// Mark the child at its real spawn boundary instead of translating the work
// interval or suppressing AppKit's invariant.
extern int posix_spawnattr_setprocesstype_np(posix_spawnattr_t *attr,
                                              int processType);
#define MACWS_POSIX_SPAWN_PROC_TYPE_APP_DEFAULT 0x00000100

static const char *const kLogPath = "/var/mobile/Library/Logs/MacWSHostd.log";
static const char *const kPreviousLogPath =
    "/var/mobile/Library/Logs/MacWSHostd.log.previous";
static const off_t kMaximumLogBytes = 16 * 1024 * 1024;
static const char *const kStartupLogPath =
    "/var/mobile/Library/Logs/MacWSStartup.log";
static const char *const kDesktopRepairLogPath =
    "/var/mobile/Library/Logs/MacWSDesktopRepair.log";
static const char *const kGUIStartState =
    "/tmp/macos_gui_start.state";
static const char *const kPostinstLog = "/var/jb/var/mobile/postinst.log";
static const char *const kRootFS = "/var/mnt/rootfs";
static const char *const kMacWSHostExecutable =
    "/var/jb/Applications/MacWSHost.app/MacWSHost";
static const char *const kProviderImportRoot =
    "/var/mnt/rootfs/Users/Shared/MacWS Imports";
static const char *const kGUI = "/var/jb/usr/macOS/bin/macos_gui.sh";
static const char *const kBash = "/var/jb/usr/bin/bash";
static const char *const kLaunchctl = "/var/jb/usr/bin/launchctl";
static const char *const kKillall = "/var/jb/usr/bin/killall";
static const char *const kChrootExec = "/var/jb/usr/macOS/bin/launchdchrootexec";
static const char *const kWorkspaceCtl = "/usr/local/bin/macwsworkspacectl";
static const char *const kPostinst = "/var/jb/usr/macOS/bin/postinst.sh";
static const char *const kSettingsExtensionsRuntime =
    "/var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh";
static const char *const kSettingsExtensionsRuntimeLog =
    "/var/jb/var/mobile/settings-extensions-runtime.log";
static const char *const kFrame = "/var/mnt/rootfs/private/tmp/macws_vnc_fb";
static const char *const kInputSocket = "/var/mnt/rootfs/private/tmp/macws_host_input.sock";
static const char *const kVNCPointerProxySocket =
    "/var/mnt/rootfs/private/tmp/macws_vnc_pointer_proxy.sock";
static const char *const kCaptureFlag = "/var/mnt/rootfs/tmp/macws_capture_final";
static const char *const kCaptureAck = "/var/mnt/rootfs/tmp/macws_capture_done";
static const char *const kWindowServerLog = "/var/jb/var/mobile/WindowServer.err";
static const char *const kSafetyTrip = "/tmp/macws_safety_trip";
static const char *const kWorkspaceSleepState =
    "/var/mobile/Library/Logs/MacWSWorkspaceSleep.plist";
static const char *const kWindowServerLabel =
    "UIKitApplication:com.macwsguide.windowserver";
static const char *const kInputLabel =
    "UIKitApplication:com.macwsguide.input";
static const char *const kDisplayLabel =
    "UIKitApplication:com.macwsguide.display";
static const char *const kDockLabel = "com.macwsguide.dock";
static const char *const kVSCodeLabel =
    "UIKitApplication:com.macwsguide.vscode";
static const char *const kVSCodePlist =
    "/var/jb/usr/macOS/gui-launchd/com.macwsguide.vscode.plist";
static const char *const kVSCodeLog = "/var/jb/var/mobile/vscode.log";
static const char *const kVSCodeHealthMarker =
    "/tmp/vscode-health-marker";
static const char *const kCoreAudioLabel = "com.apple.audio.coreaudiod";
static const char *const kCoreAudioPlist =
    "/var/jb/usr/macOS/gui-launchd/com.macwsguide.coreaudiod.plist";
static const char *const kAudioComponentRegistrarLabel =
    "com.apple.macosbooter.audio.AudioComponentRegistrar";
static const char *const kAudioComponentRegistrarPlist =
    "/var/jb/usr/macOS/gui-launchd/com.macwsguide.audiocomponentregistrar.plist";
static const char *const kAudioOutputLabel =
    "com.macwsguide.audio-output";
static const char *const kAudioOutputPlist =
    "/var/jb/usr/macOS/gui-launchd/com.macwsguide.audio-output.plist";
static const char *const kVSCodeURLSocket =
    "/var/mnt/rootfs" MACWS_VSCODE_URL_SOCKET_PATH;
static const char *const kVSCodeExecutable =
    "/Applications/Visual Studio Code.app/Contents/MacOS/Electron";
// Current VS Code's bundle metadata names the thin launcher `Code`, while the
// production launchd job intentionally runs the equivalent `Electron` entry
// with MacWS's JIT/environment contract. Dock resolves CFBundleExecutable and
// therefore presents this path to the generic launch boundary.
static const char *const kVSCodeBundleExecutable =
    "/Applications/Visual Studio Code.app/Contents/MacOS/Code";
static const char *const kGeekbenchExecutable =
    "/Applications/Geekbench 6.app/Contents/MacOS/Geekbench 6";
static const char *const kGeekbenchBackendExecutable =
    "/Applications/Geekbench 6.app/Contents/Resources/geekbench_aarch64";
static const char *const kGeekbenchLabel =
    "UIKitApplication:com.macwsguide.geekbench";
static const char *const kGeekbenchPlist =
    "/var/jb/usr/macOS/gui-launchd/com.macwsguide.geekbench.plist";
static const char *const kUIKitSystemPlist =
    "/var/jb/usr/macOS/LaunchDaemons/com.apple.uikitsystemapp.plist";
static const char *const kUIKitSystemExecutable =
    "/System/Library/CoreServices/UIKitSystem.app/Contents/MacOS/UIKitSystem";
static const char *const kMapsExecutable =
    "/System/Applications/Maps.app/Contents/MacOS/Maps";
static const char *const kMapsHostCarrierMarker =
    "/tmp/macws-maps-host-carrier.pid";
static const char *const kWeatherExecutable =
    "/System/Applications/Weather.app/Contents/MacOS/Weather";
static const char *const kWeatherBundleIdentifier = "com.apple.weather";
static const char *const kWeatherContainerHome =
    "/Users/mobile/Library/Containers/com.apple.weather/Data";
static const char *const kWeatherKnownSceneSessions =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/Saved Application State/com.apple.weather~iosmac.savedState/"
    "KnownSceneSessions/data.data";
static const char *const kWeatherKnownSceneSessionsLegacyPreBootstrap =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/Saved Application State/com.apple.weather~iosmac.savedState/"
    "KnownSceneSessions/data.data.macws-pre-bootstrap";
static const char *const kWeatherKnownSceneSessionsLegacyLastStale =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/Saved Application State/com.apple.weather~iosmac.savedState/"
    "KnownSceneSessions/data.data.macws-last-stale";
static const char *const kWeatherKnownSceneSessionsBackup =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/.macws-weather-known-scene-last.data";
static const char *const kWeatherKnownSceneSessionsLegacyBackup =
    "/var/mnt/rootfs/Users/mobile/Library/Containers/com.apple.weather/Data/"
    "Library/.macws-weather-known-scene-legacy.data";
static const char *const kAsphaltExecutable =
    "/Applications/Asphalt.app/Contents/MacOS/Asphalt";
static const char *const kAsphaltBundleIdentifier =
    "com.gameloft.asphalt9mac";
static const char *const kAsphaltContainerHome =
    "/Users/mobile/Library/Containers/com.gameloft.asphalt9mac/Data";
static const char *const kCatalystRequestPath =
    "/tmp/macws-catalyst-launch-request.plist";
static const char *const kSteamLabel =
    "UIKitApplication:com.macwsguide.steam";
static const char *const kSteamPlist =
    "/var/jb/usr/macOS/gui-launchd/com.macwsguide.steam.runtime.plist";
static const char *const kSteamOuterExecutable =
    "/Applications/Steam.app/Contents/MacOS/steam_osx";
static const char *const kSteamLiveExecutable =
    "/Users/root/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx";
static const char *const kSteamUIExecutable =
    "/Users/root/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/Steam Helper";
static const char *const kSteamOverlayExecutable =
    "/Users/root/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/gameoverlayui";
static const char *const kStrayExecutable =
    "/Users/root/Library/Application Support/Steam/steamapps/macws-runtime/Stray/Stray.app/Contents/MacOS/Stray-Mac-Shipping";
static const char *const kMetalCompatWorkingDirectory =
    "/var/jb/var/mobile/macws-metal-compat";
static const char *const kMetalCompatExactDirectory =
    "/var/mnt/rootfs/usr/local/share/macws/stray/exact";
static const char *const kMetalCompatConverter =
    "/var/jb/usr/macOS/bin/repack_metallib_macabi.py";
static const char *const kMetalCompatInstaller =
    "/var/jb/usr/macOS/bin/install_stray_exact_metallib.py";
static const char *const kProcursusPython = "/var/jb/usr/bin/python3";
static const char *const kLLVM16Dis =
    "/var/jb/usr/lib/llvm-16/bin/llvm-dis";
static const char *const kLLVM16As =
    "/var/jb/usr/lib/llvm-16/bin/llvm-as";
static const char *const kMetalCompatLog =
    "/var/jb/var/mobile/macws-metal-compat.log";
static const char *const kMetalCompatProbeExecutable =
    "/var/jb/usr/macOS/bin/macws_control_probe";
static CFStringRef const kMapsHostLaunchNotification =
    CFSTR("com.macwsguide.host.launch-maps");
static CFStringRef const kCatalystHostLaunchNotification =
    CFSTR("com.macwsguide.host.launch-catalyst");
static pid_t WaitForRunningRootExecutable(NSString *rootPath,
                                          NSTimeInterval timeout);
static pid_t FindRunningSteamExecutable(void);
static BOOL SteamPIDMatchesProductionJob(pid_t pid, NSString *actualPath);
static void TrackApplicationSession(NSString *identifier,
                                    NSString *rootPath, pid_t pid);
static void ApplicationSessionObservedExit(pid_t pid, NSString *identifier,
                                           NSString *witness);
static void StartApplicationSessionSupervisor(void);
static void StartWorkspacePowerCoordinator(void);

static dispatch_queue_t gControlQueue;
static dispatch_queue_t gLogQueue;
static dispatch_queue_t gSteamSemaphoreQueue;
static dispatch_queue_t gSteamMachRendezvousQueue;
static dispatch_queue_t gMetalCompatQueue;
static dispatch_queue_t gProviderFileQueue;
static dispatch_source_t gSteamSemaphoreWaitListener;
static int gSteamSemaphoreWaitListenerDescriptor = -1;
static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;
static os_unfair_lock gStatusJobsLock = OS_UNFAIR_LOCK_INIT;
static BOOL gBusy;
static NSString *gPhase = @"就绪";
static NSString *gLastError = @"";
static BOOL gStartupOperationActive;
static BOOL gStartupRetryAvailable;
static time_t gStartupBeganAt;
static pid_t gActiveAppPID;
static NSString *gActiveAppID = @"";
// All application entry points (Control Center, Dock and direct AppKit
// relaunch) converge on this process-identity table.  It is deliberately
// owned by gControlQueue so launch, exit observation and orphan cleanup
// form one serialized session transaction instead of racing independent
// one-shot repairs.
static NSMutableDictionary<NSString *, NSMutableDictionary *> *gApplicationSessions;
static dispatch_source_t gApplicationSupervisorTimer;
static pid_t gObservedOrphanOverlayPID;
static CFAbsoluteTime gObservedOrphanOverlaySince;
// Steam's overlay is discovered while a Steam session is live and then
// followed by exact PID/path identity.  Do not rescan every process once per
// second after Steam has exited: on-device sampling showed that the old idle
// supervisor spent most of its runnable time in that global scan.
static pid_t gKnownSteamOverlayPID;
static pid_t gKnownStrayPID;
static BOOL gSteamProcessDiscoveryPrimed;
static BOOL gSteamOwnerWasPresent;
static CFAbsoluteTime gNextSteamProcessDiscovery;
static _Atomic bool gWorkspaceSleeping;
static uint64_t gWorkspacePowerGeneration;
static NSArray<NSDictionary *> *gSuspendedWorkspaceProcesses;
static int gLockStateToken = -1;
static int gScreenBlankToken = -1;

typedef struct {
    uint64_t generation;
    uint32_t references;
    uint32_t value;
    BOOL unlinked;
    // Retained for the complete POSIX generation, including after unlink.
    // Protocol v23 makes this vnode the counter authority shared with the
    // chroot clients; entry->value is only a synchronized log/reply mirror.
    int stateDescriptor;
    char name[112];
    mach_port_t waiterPorts[32];
    uint32_t waiterCount;
    int waiterSockets[32];
    uint64_t waiterSocketRequestIDs[32];
    uint64_t waiterSocketIDs[32];
    uint32_t waiterSocketCount;
    uint64_t pollingWaiters[64];
    uint8_t pollingWaiterGranted[64];
    uint32_t pollingWaiterCount;
} MacWSSteamSemaphoreEntry;

static NSMutableDictionary<NSString *, NSValue *> *gSteamSemaphoreNames;
static NSMutableDictionary<NSString *, NSNumber *> *gSteamMachRendezvousPorts;
static NSMutableDictionary<NSNumber *, NSValue *> *gSteamSemaphoreGenerations;
// name -> generation returned by the latest successful unlink. A protocol-v23
// recreate must present that exact receipt before it may retire a name won by
// a racing opener. This keeps ordinary O_CREAT|O_EXCL strict.
static NSMutableDictionary<NSString *, NSNumber *> *
    gSteamSemaphoreUnlinkReceipts;
static uint64_t gSteamSemaphoreNextGeneration;
static NSString *gSteamSemaphoreEpoch;

static void HostLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void HostLog(NSString *format, ...) {
    // HostLog is already the daemon's authoritative timestamped persistent
    // channel. Mirroring every Steam semaphore/rendezvous event through
    // NSLog wrote the same stream into launchd's stderr file as well; runtime
    // on 2026-08-28 found 230 MB and 173 MB copies with matching tail lines.
    // Keep framework/uncaught diagnostics on launchd stderr, but do not send
    // this deliberately high-rate application log there a second time.
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    dispatch_async(gLogQueue ?: dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            static off_t logBytes = 0;
            static BOOL logBytesKnown = NO;
            NSString *line = [NSString stringWithFormat:@"%.3f %@\n",
                              NSDate.date.timeIntervalSince1970, message];
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (!logBytesKnown) {
                struct stat status = {0};
                if (stat(kLogPath, &status) == 0 && status.st_size > 0) {
                    logBytes = status.st_size;
                }
                logBytesKnown = YES;
            }
            if (logBytes >= kMaximumLogBytes ||
                data.length > (NSUInteger)(kMaximumLogBytes - logBytes)) {
                (void)unlink(kPreviousLogPath);
                if (rename(kLogPath, kPreviousLogPath) == 0 ||
                    errno == ENOENT) {
                    logBytes = 0;
                }
            }
            int fd = open(kLogPath,
                          O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
            if (fd < 0) return;
            ssize_t written = write(fd, data.bytes, data.length);
            if (written > 0) logBytes += written;
            close(fd);
        }
    });
}

static void SetState(BOOL busy, NSString *phase, NSString *error) {
    os_unfair_lock_lock(&gStateLock);
    gBusy = busy;
    if (phase) gPhase = [phase copy];
    if (error) gLastError = [error copy];
    os_unfair_lock_unlock(&gStateLock);
    HostLog(@"state busy=%@ phase=%@ error=%@", busy ? @"YES" : @"NO",
            phase ?: gPhase, error ?: gLastError);
}

static BOOL HasExecutableFileMode(const char *path) {
    struct stat status = {0};
    return path && stat(path, &status) == 0 && S_ISREG(status.st_mode) &&
        (status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
}

// Catalyst's responsible-process carrier supplies HOME explicitly, but the
// mounted Ventura filesystem does not have containermanagerd to materialize a
// first-run container.  Runtime on iPad13,6 showed Weather's executable and
// UIKitSystem service present while this one directory was absent; the
// already-working Asphalt carrier has the concrete ownership/mode contract
// mirrored below.  Only fixed allowlist constants reach this helper.
static BOOL EnsureCatalystContainer(const char *containerHome,
                                    NSString **message) {
    if (!containerHome ||
        strncmp(containerHome, "/Users/mobile/Library/Containers/",
                strlen("/Users/mobile/Library/Containers/")) != 0 ||
        strstr(containerHome, "..") != NULL) {
        if (message) *message = @"Catalyst 容器路径不在允许范围内";
        return NO;
    }
    NSString *dataPath = [@(kRootFS) stringByAppendingString:@(containerHome)];
    if (![dataPath.lastPathComponent isEqualToString:@"Data"]) {
        if (message) *message = @"Catalyst 容器必须以 Data 为根";
        return NO;
    }
    NSString *containerPath = dataPath.stringByDeletingLastPathComponent;
    NSArray<NSDictionary<NSString *, id> *> *directories = @[
        @{@"path": containerPath, @"mode": @(0700)},
        @{@"path": dataPath, @"mode": @(0700)},
        @{@"path": [dataPath stringByAppendingPathComponent:@"Documents"],
          @"mode": @(0755)},
        @{@"path": [dataPath stringByAppendingPathComponent:@"Library"],
          @"mode": @(0755)},
    ];
    for (NSDictionary<NSString *, id> *entry in directories) {
        NSString *path = entry[@"path"];
        mode_t mode = (mode_t)[entry[@"mode"] unsignedShortValue];
        const char *fileSystemPath = path.fileSystemRepresentation;
        struct stat status = {0};
        if (lstat(fileSystemPath, &status) != 0) {
            if (errno != ENOENT || mkdir(fileSystemPath, mode) != 0) {
                if (message) *message = [NSString stringWithFormat:
                    @"无法创建 Catalyst 容器 %@（errno=%d）",
                    path.lastPathComponent, errno];
                return NO;
            }
        } else if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
            if (message) *message = [NSString stringWithFormat:
                @"Catalyst 容器路径不是目录：%@", path];
            return NO;
        }
        if (chown(fileSystemPath, 501, 501) != 0 ||
            chmod(fileSystemPath, mode) != 0) {
            if (message) *message = [NSString stringWithFormat:
                @"无法设置 Catalyst 容器权限 %@（errno=%d）",
                path.lastPathComponent, errno];
            return NO;
        }
    }
    return YES;
}

// Runtime-confirmed on iPad13,6 with Weather pids 79331/89014/89042: UIKit
// first tracked the current process's newly requested persistent scene ID,
// then restored the preceding process's ID from this exact archive. FuseBoard
// reused one FUScene identifier for both transactions, after which
// UINSApplicationDelegate logged "untracked scene, ignoring" and the real
// Weather NSWindow remained onscreen=false with CGSCopySpacesForWindows=().
// A clean-launch A/B at pid 90330 then moved data.data but left two earlier
// MacWS backups in KnownSceneSessions; UIKit still restored the ID contained
// by those backups. Move every exact, known MacWS filename out of Saved
// Application State as well as the stock archive. Weather locations and
// preferences live elsewhere and remain untouched. Two fixed backups retain
// the last stock/legacy inputs without accumulating files across launches.
static BOOL MoveWeatherSceneStateFile(const char *source,
                                      const char *destination,
                                      const char *label,
                                      long long *bytesMoved,
                                      NSString **message) {
    struct stat stateStatus = {0};
    if (lstat(source, &stateStatus) != 0) {
        if (errno == ENOENT) return YES;
        if (message) *message = [NSString stringWithFormat:
            @"无法检查天气场景恢复记录（errno=%d）", errno];
        return NO;
    }
    if (!S_ISREG(stateStatus.st_mode) || S_ISLNK(stateStatus.st_mode) ||
        stateStatus.st_nlink != 1 ||
        (stateStatus.st_uid != 0 && stateStatus.st_uid != 501)) {
        HostLog(@"weather scene-restoration reject mode=%#o uid=%u links=%u",
                stateStatus.st_mode, stateStatus.st_uid,
                (unsigned)stateStatus.st_nlink);
        if (message) *message = @"天气场景恢复记录的类型或所有者异常，未修改";
        return NO;
    }

    struct stat backupStatus = {0};
    int backupResult = lstat(destination, &backupStatus);
    int backupError = errno;
    if (backupResult == 0 &&
        (!S_ISREG(backupStatus.st_mode) ||
         S_ISLNK(backupStatus.st_mode) || backupStatus.st_nlink != 1 ||
         (backupStatus.st_uid != 0 && backupStatus.st_uid != 501))) {
        HostLog(@"weather scene-restoration backup-reject mode=%#o uid=%u "
                "links=%u", backupStatus.st_mode, backupStatus.st_uid,
                (unsigned)backupStatus.st_nlink);
        if (message) *message = @"天气场景恢复备份的类型或所有者异常，未修改";
        return NO;
    } else if (backupResult != 0 && backupError != ENOENT) {
        if (message) *message = [NSString stringWithFormat:
            @"无法检查天气场景恢复备份（errno=%d）", backupError];
        return NO;
    }

    if (rename(source, destination) != 0) {
        if (message) *message = [NSString stringWithFormat:
            @"无法轮换天气场景恢复记录（errno=%d）", errno];
        return NO;
    }
    if (bytesMoved) *bytesMoved += (long long)stateStatus.st_size;
    HostLog(@"weather scene-restoration moved label=%s bytes=%lld uid=%u "
            "backup=%s", label, (long long)stateStatus.st_size,
            stateStatus.st_uid, destination);
    return YES;
}

static BOOL RotateWeatherKnownSceneSessions(NSString **message) {
    long long bytesMoved = 0;
    if (!MoveWeatherSceneStateFile(
            kWeatherKnownSceneSessionsLegacyPreBootstrap,
            kWeatherKnownSceneSessionsLegacyBackup, "legacy-pre-bootstrap",
            &bytesMoved, message)) return NO;
    if (!MoveWeatherSceneStateFile(
            kWeatherKnownSceneSessionsLegacyLastStale,
            kWeatherKnownSceneSessionsLegacyBackup, "legacy-last-stale",
            &bytesMoved, message)) return NO;
    if (!MoveWeatherSceneStateFile(
            kWeatherKnownSceneSessions, kWeatherKnownSceneSessionsBackup,
            "stock", &bytesMoved, message)) return NO;
    HostLog(@"weather scene-restoration clean moved-total-bytes=%lld",
            bytesMoved);
    return YES;
}

// Build a private, deterministic envp for one child. posix_spawn consumes the
// strings synchronously, so the caller frees it immediately after the call.
// Existing entries with the same key are replaced instead of relying on the
// undefined first/last behavior of duplicate environment variables.
static char **CopyEnvironmentAdding(const char *const *additions,
                                    size_t additionCount) {
    size_t inheritedCount = 0;
    for (char **cursor = environ; cursor && *cursor; cursor++) {
        BOOL replaced = NO;
        for (size_t index = 0; index < additionCount; index++) {
            const char *equals = additions[index]
                ? strchr(additions[index], '=') : NULL;
            size_t keyLength = equals
                ? (size_t)(equals - additions[index]) : 0;
            if (keyLength != 0 &&
                strncmp(*cursor, additions[index], keyLength) == 0 &&
                (*cursor)[keyLength] == '=') {
                replaced = YES;
                break;
            }
        }
        if (!replaced) inheritedCount++;
    }

    char **result = calloc(inheritedCount + additionCount + 1,
                           sizeof(*result));
    if (!result) return NULL;
    size_t output = 0;
    for (char **cursor = environ; cursor && *cursor; cursor++) {
        BOOL replaced = NO;
        for (size_t index = 0; index < additionCount; index++) {
            const char *equals = additions[index]
                ? strchr(additions[index], '=') : NULL;
            size_t keyLength = equals
                ? (size_t)(equals - additions[index]) : 0;
            if (keyLength != 0 &&
                strncmp(*cursor, additions[index], keyLength) == 0 &&
                (*cursor)[keyLength] == '=') {
                replaced = YES;
                break;
            }
        }
        if (!replaced) result[output++] = strdup(*cursor);
    }
    for (size_t index = 0; index < additionCount; index++)
        result[output++] = strdup(additions[index]);
    for (size_t index = 0; index < output; index++) {
        if (!result[index]) {
            for (size_t cleanup = 0; cleanup < output; cleanup++)
                free(result[cleanup]);
            free(result);
            return NULL;
        }
    }
    return result;
}

static void FreeCopiedEnvironment(char **environment) {
    if (!environment) return;
    for (char **cursor = environment; *cursor; cursor++) free(*cursor);
    free(environment);
}

static uint64_t ArmCapture(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) return 0;
    static _Atomic uint64_t lastGeneration = 0;
    uint64_t generation = (uint64_t)now.tv_sec * 1000000000ull +
                          (uint64_t)now.tv_nsec;
    uint64_t previous = atomic_load(&lastGeneration);
    while (generation <= previous) generation = previous + 1;
    atomic_store(&lastGeneration, generation);

    char value[48];
    int length = snprintf(value, sizeof(value), "%llu\n",
                          (unsigned long long)generation);
    int fd = open(kCaptureFlag,
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return 0;
    ssize_t written = write(fd, value, (size_t)length);
    int savedErrno = errno;
    close(fd);
    if (written != length) {
        errno = written < 0 ? savedErrno : EIO;
        (void)unlink(kCaptureFlag);
        return 0;
    }
    HostLog(@"capture armed generation=%llu",
            (unsigned long long)generation);
    return generation;
}

static void RemovePath(const char *path) {
    if (unlink(path) != 0 && errno != ENOENT)
        HostLog(@"unlink failed path=%s errno=%d (%s)", path, errno, strerror(errno));
}

static int RunCommandWithEnvironmentToLog(const char *const argv[],
                                          char *const environment[],
                                          BOOL waitForExit,
                                          const char *logPath) {
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int logFD = open(logPath ? logPath : kLogPath,
                     O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (logFD >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFD);
    }
    pid_t pid = 0;
    int spawnError = posix_spawn(&pid, argv[0], &actions, NULL,
                                 (char *const *)argv,
                                 environment ? environment : environ);
    posix_spawn_file_actions_destroy(&actions);
    if (logFD >= 0) close(logFD);
    if (spawnError != 0) {
        HostLog(@"spawn failed executable=%s error=%d (%s)", argv[0],
                spawnError, strerror(spawnError));
        return 128 + spawnError;
    }
    HostLog(@"spawned pid=%d executable=%s wait=%@", pid, argv[0],
            waitForExit ? @"YES" : @"NO");
    if (!waitForExit) return 0;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) continue;
        HostLog(@"waitpid failed pid=%d errno=%d", pid, errno);
        return 127;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 126;
}

static int RunCommandWithEnvironment(const char *const argv[],
                                     char *const environment[],
                                     BOOL waitForExit) {
    return RunCommandWithEnvironmentToLog(argv, environment, waitForExit,
                                          kLogPath);
}

static int RunCommand(const char *const argv[], BOOL waitForExit) {
    return RunCommandWithEnvironment(argv, environ, waitForExit);
}

static int RunCommandToLog(const char *const argv[], BOOL waitForExit,
                           const char *logPath) {
    return RunCommandWithEnvironmentToLog(argv, environ, waitForExit,
                                          logPath);
}

static int SpawnMacOSApplication(pid_t *pid,
                                 const char *path,
                                 const posix_spawn_file_actions_t *actions,
                                 char *const argv[],
                                 char *const environment[],
                                 BOOL applicationProcessType) {
    posix_spawnattr_t attributes;
    int error = posix_spawnattr_init(&attributes);
    if (error != 0) return error;

    // macwshostd is a long-lived launchd/XPC service.  posix_spawn inherits
    // the calling thread's signal mask unless POSIX_SPAWN_SETSIGMASK is set;
    // a dispatch worker may therefore launch Terminal with interactive
    // signals blocked.  AppKit then starts the shell and every foreground
    // command with the same mask, so the PTY can echo ^C while SIGINT never
    // reaches the job.  Establish the normal exec boundary explicitly.
    sigset_t emptyMask;
    sigemptyset(&emptyMask);
    error = posix_spawnattr_setsigmask(&attributes, &emptyMask);

    sigset_t defaultSignals;
    sigemptyset(&defaultSignals);
    const int interactiveSignals[] = {
        SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM,
        SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU,
    };
    for (size_t index = 0;
         error == 0 && index < sizeof(interactiveSignals) /
                                sizeof(interactiveSignals[0]);
         index++) {
        if (sigaddset(&defaultSignals, interactiveSignals[index]) != 0)
            error = errno;
    }
    if (error == 0)
        error = posix_spawnattr_setsigdefault(&attributes, &defaultSignals);
    // An application owns its lifetime, not the launcher's launchd process
    // group. Runtime-confirmed on 2026-09-19: Word 8439 and Terminal 13515
    // both inherited hostd's PGID 92633. Reloading that job can therefore
    // include user documents and shells in launchd's group cleanup. Set the
    // child's group atomically at spawn (0 means the new child's own PID),
    // retaining waitpid/reaping and the existing AppKit scheduling contract.
    // The package installer separately defers reload for old shared groups;
    // this only establishes the invariant for newly launched applications.
    if (error == 0)
        error = posix_spawnattr_setpgroup(&attributes, 0);
    if (error == 0) {
        error = posix_spawnattr_setflags(
            &attributes, POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF |
                         POSIX_SPAWN_SETPGROUP);
    }
    if (error == 0 && applicationProcessType) {
        error = posix_spawnattr_setprocesstype_np(
            &attributes, MACWS_POSIX_SPAWN_PROC_TYPE_APP_DEFAULT);
    }
    if (error == 0) {
        error = posix_spawn(pid, path, actions, &attributes, argv,
                            environment ? environment : environ);
    }
    posix_spawnattr_destroy(&attributes);
    return error;
}

static NSString *CaptureCommand(const char *const argv[], NSUInteger limit) {
    int pipes[2];
    if (pipe(pipes) != 0) return @"";
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    posix_spawn_file_actions_addclose(&actions, pipes[1]);
    pid_t pid = 0;
    int error = posix_spawn(&pid, argv[0], &actions, NULL,
                            (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipes[1]);
    if (error != 0) {
        close(pipes[0]);
        return [NSString stringWithFormat:@"spawn %s: %s", argv[0], strerror(error)];
    }
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[4096];
    for (;;) {
        ssize_t count = read(pipes[0], buffer, sizeof(buffer));
        if (count > 0) {
            if (data.length + (NSUInteger)count > limit) {
                NSUInteger skip = data.length + (NSUInteger)count - limit;
                if (skip < data.length)
                    [data replaceBytesInRange:NSMakeRange(0, skip) withBytes:NULL length:0];
                else
                    [data setLength:0];
            }
            NSUInteger room = limit - data.length;
            [data appendBytes:buffer length:MIN((NSUInteger)count, room)];
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close(pipes[0]);
    (void)waitpid(pid, NULL, 0);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

static BOOL InspectJob(const char *label, int *pidOut, BOOL *loadedOut) {
    const char *argv[] = {kLaunchctl, "list", label, NULL};
    NSString *output = CaptureCommand(argv, 32768);
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"\\\"PID\\\"\\s*=\\s*([0-9]+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:output options:0
                                                     range:NSMakeRange(0, output.length)];
    int pid = 0;
    if (match.numberOfRanges > 1)
        pid = [[output substringWithRange:[match rangeAtIndex:1]] intValue];
    if (loadedOut) {
        NSString *marker = [NSString stringWithFormat:@"\"Label\" = \"%s\"",
                            label];
        *loadedOut = [output containsString:marker];
    }
    if (pidOut) *pidOut = pid;
    return pid > 0;
}

static BOOL JobHasPID(const char *label, int *pidOut) {
    return InspectJob(label, pidOut, NULL);
}

// AddStatus is the UI's polling hot path.  Do not synthesize one logical
// status reply from several independently spawned `launchctl list <label>`
// commands: on the production iPad that accumulated 27,152 hostd forks, and
// a 2026-08-27 live witness had all three calls report false while one
// `launchctl list` snapshot contained WindowServer=49273, input=49266 and
// Dock=63979.  Read the launchd namespace once so the reply is coherent.  A
// failed snapshot may reuse only a recent PID which the kernel still reports
// alive; a successful snapshot, including an absent job, always replaces the
// cache immediately.
static void InspectStatusJobs(int *windowServerPIDOut,
                              int *inputPIDOut,
                              int *dockPIDOut) {
    const char *argv[] = {kLaunchctl, "list", NULL};
    NSString *output = CaptureCommand(argv, 32768);
    int windowServerPID = 0;
    int inputPID = 0;
    int dockPID = 0;
    NSUInteger parsedRows = 0;
    for (NSString *line in [output componentsSeparatedByCharactersInSet:
             NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSString *> *columns = [line componentsSeparatedByString:@"\t"];
        if (columns.count < 3) continue;
        NSInteger pid = columns[0].integerValue;
        if (pid <= 1) continue;
        parsedRows++;
        NSString *label = columns[2];
        if ([label isEqualToString:@(kWindowServerLabel)])
            windowServerPID = (int)pid;
        else if ([label isEqualToString:@(kInputLabel)])
            inputPID = (int)pid;
        else if ([label isEqualToString:@(kDockLabel)])
            dockPID = (int)pid;
    }

    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    static int cachedWindowServerPID = 0;
    static int cachedInputPID = 0;
    static int cachedDockPID = 0;
    static NSTimeInterval cachedAt = 0;
    os_unfair_lock_lock(&gStatusJobsLock);
    if (parsedRows != 0) {
        cachedWindowServerPID = windowServerPID;
        cachedInputPID = inputPID;
        cachedDockPID = dockPID;
        cachedAt = now;
    } else if (cachedAt != 0 && now - cachedAt <= 5.0) {
        windowServerPID = cachedWindowServerPID;
        inputPID = cachedInputPID;
        dockPID = cachedDockPID;
    }
    os_unfair_lock_unlock(&gStatusJobsLock);

    // The fallback is only a short transport-failure grace period.  It cannot
    // turn a dead cached job into a positive status witness.
    if (windowServerPID > 1 && kill(windowServerPID, 0) != 0)
        windowServerPID = 0;
    if (inputPID > 1 && kill(inputPID, 0) != 0)
        inputPID = 0;
    if (dockPID > 1 && kill(dockPID, 0) != 0)
        dockPID = 0;

    if (windowServerPIDOut) *windowServerPIDOut = windowServerPID;
    if (inputPIDOut) *inputPIDOut = inputPID;
    if (dockPIDOut) *dockPIDOut = dockPID;
}

static BOOL WaitForJobPID(const char *label, NSTimeInterval timeout,
                          int *pidOut) {
    int pid = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        if (JobHasPID(label, &pid)) {
            if (pidOut) *pidOut = pid;
            return YES;
        }
        usleep(100000);
    } while (deadline.timeIntervalSinceNow > 0);
    if (pidOut) *pidOut = 0;
    return NO;
}

static BOOL RootFSReady(void) {
    static const char *const paths[] = {
        "/var/mnt/rootfs/bin/bash",
        "/var/mnt/rootfs/System/Library/PrivateFrameworks/"
            "SkyLight.framework/Resources/WindowServer",
        kGUI,
        kChrootExec,
    };
    static const int modes[] = {X_OK, X_OK, R_OK, X_OK};
    static const BOOL chrootExecutables[] = {YES, YES, NO, NO};
    int errors[sizeof(paths) / sizeof(paths[0])] = {0};
    uint32_t readyMask = 0;
    for (NSUInteger index = 0;
         index < sizeof(paths) / sizeof(paths[0]); index++) {
        errno = 0;
        if (chrootExecutables[index]) {
            // These macOS binaries are executed by launchdchrootexec after it
            // changes root, not by this iOS daemon.  iOS MAC policy can make
            // access(X_OK) report EPERM for the hostd security principal even
            // while the real chroot launcher executes the same vnode.  Check
            // the invariant hostd actually owns here: the mounted vnode must
            // be reachable, regular, and carry an executable mode bit.  The
            // subsequent startup path still executes it and waits for the
            // real WindowServer/input/display endpoints before declaring the
            // workspace ready.
            struct stat status = {0};
            if (stat(paths[index], &status) == 0 &&
                S_ISREG(status.st_mode) &&
                (status.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0) {
                readyMask |= 1u << index;
            } else {
                errors[index] = errno ?: EACCES;
            }
        } else if (access(paths[index], modes[index]) == 0) {
            readyMask |= 1u << index;
        } else {
            errors[index] = errno;
        }
    }

    // Keep one transition witness for the daemon's own filesystem view. This
    // is intentionally not a bypass: the UI must stay disabled when the
    // launcher itself cannot prove the files are reachable, but the exact
    // errno is required to distinguish a missing mount from a process-policy
    // failure. AddStatus polls frequently, so log only when the result changes.
    static uint64_t previousSignature = UINT64_MAX;
    uint64_t signature = readyMask;
    for (NSUInteger index = 0;
         index < sizeof(errors) / sizeof(errors[0]); index++) {
        signature = (signature * 1315423911u) ^ (uint32_t)errors[index];
    }
    if (signature != previousSignature) {
        previousSignature = signature;
        HostLog(@"rootfs-probe ready=%@ mask=%#x "
                "bash-errno=%d ws-errno=%d gui-errno=%d exec-errno=%d",
                readyMask == 0xf ? @"YES" : @"NO", readyMask,
                errors[0], errors[1], errors[2], errors[3]);
    }
    return readyMask == 0xf;
}

static BOOL ReadFrame(uint32_t *width, uint32_t *height) {
    uint32_t header[4] = {0};
    int fd = open(kFrame, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat st = {0};
    if (fstat(fd, &st) != 0) {
        close(fd);
        return NO;
    }
    ssize_t count = read(fd, header, sizeof(header));
    close(fd);
    if (count != sizeof(header) || header[0] != MACWS_FRAME_MAGIC ||
        header[1] == 0 || header[2] == 0 || header[1] > 16384 ||
        header[2] > 16384 || header[3] != header[1] * 4u)
        return NO;
    uint64_t required = sizeof(header) + (uint64_t)header[3] * header[2];
    if ((uint64_t)st.st_size < required) return NO;
    if (width) *width = header[1];
    if (height) *height = header[2];
    return YES;
}

static BOOL ReadCaptureAck(int expectedPID, uint64_t expectedGeneration,
                           uint64_t *generationOut) {
    char value[96] = {0};
    int fd = open(kCaptureAck, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    if (count <= 0) return NO;
    int pid = 0;
    unsigned long long generation = 0;
    if (sscanf(value, "%d %llu", &pid, &generation) != 2 ||
        pid != expectedPID || generation == 0 ||
        (expectedGeneration != 0 && generation != expectedGeneration))
        return NO;
    if (generationOut) *generationOut = (uint64_t)generation;
    return YES;
}

static BOOL IsSocket(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISSOCK(st.st_mode);
}

static BOOL IsAppInputSocket(pid_t pid) {
    if (pid <= 1) return NO;
    char path[128];
    snprintf(path, sizeof(path),
             "/var/mnt/rootfs/private/tmp/macws_app_input.%d.sock", pid);
    return IsSocket(path);
}

static void SetString(xpc_object_t reply, const char *key, NSString *value) {
    xpc_dictionary_set_string(reply, key, value.UTF8String ?: "");
}

static NSString *ReadSmallTextFile(const char *path, NSUInteger limit) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return @"";
    NSMutableData *data = [NSMutableData dataWithLength:limit];
    ssize_t count = read(fd, data.mutableBytes, data.length);
    close(fd);
    if (count <= 0) return @"";
    data.length = (NSUInteger)count;
    NSString *text = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    return [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static NSString *TailFile(const char *path, NSUInteger limit);

static NSString *GUIStartStateValue(NSString *key) {
    NSString *state = ReadSmallTextFile(kGUIStartState, 4096);
    NSString *prefix = [key stringByAppendingString:@"="];
    for (NSString *line in [state componentsSeparatedByCharactersInSet:
             NSCharacterSet.newlineCharacterSet]) {
        if ([line hasPrefix:prefix]) return [line substringFromIndex:prefix.length];
    }
    return @"";
}

static NSString *StartupPhaseDisplay(NSString *phaseCode) {
    if (!phaseCode.length) return @"检查并修复启动环境…";
    static NSDictionary<NSString *, NSString *> *phases;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        phases = @{
            @"preparing": @"正在生成启动配置…",
            @"cleaning": @"正在清理旧的服务状态…",
            @"assets": @"正在准备应用运行环境…",
            @"preflight": @"正在验证图形启动条件…",
            @"safety": @"正在启动安全保护…",
            @"trust": @"检查并修复启动环境…",
            @"services": @"正在启动 macOS 系统服务…",
            @"first-frame": @"正在等待第一帧画面…",
            @"ready": @"macOS 工作区已就绪",
        };
    });
    return phases[phaseCode] ?: @"检查并修复启动环境…";
}

static NSString *StartupLogText(time_t startupBeganAt,
                                BOOL includePostinst) {
    NSMutableString *text = [NSMutableString string];
    NSString *startup = TailFile(kStartupLogPath, 12288);
    if (startup.length) [text appendString:startup];

    struct stat postinstStatus = {0};
    BOOL currentPostinst = includePostinst &&
        stat(kPostinstLog, &postinstStatus) == 0 &&
        postinstStatus.st_mtime >= startupBeganAt;
    if (currentPostinst) {
        NSString *postinst = TailFile(kPostinstLog, 12288);
        if (postinst.length) {
            if (text.length) [text appendString:@"\n\n"];
            [text appendString:@"=== postinst.sh ===\n"];
            [text appendString:postinst];
        }
    }
    if (!text.length)
        [text appendString:@"等待启动日志…"];
    return text;
}

static void AddStatus(xpc_object_t reply) {
    int wsPID = 0;
    int inputPID = 0;
    int systemInputPID = 0;
    InspectStatusJobs(&wsPID, &inputPID, &systemInputPID);
    BOOL ws = wsPID > 1;
    BOOL inputJob = inputPID > 1;
    BOOL systemInputReady = systemInputPID > 1 &&
        IsAppInputSocket(systemInputPID);
    uint32_t width = 0, height = 0;
    uint64_t frameGeneration = 0;
    BOOL frame = ws && ReadFrame(&width, &height) &&
        ReadCaptureAck(wsPID, 0, &frameGeneration);
    BOOL busy;
    BOOL startupActive;
    BOOL startupRetryAvailable;
    time_t startupBeganAt;
    NSString *phase;
    NSString *lastError;
    os_unfair_lock_lock(&gStateLock);
    busy = gBusy;
    startupActive = gStartupOperationActive;
    startupRetryAvailable = gStartupRetryAvailable;
    startupBeganAt = gStartupBeganAt;
    phase = gPhase;
    lastError = gLastError;
    pid_t activeAppPID = gActiveAppPID;
    NSString *activeAppID = gActiveAppID;
    if (activeAppPID > 1 && kill(activeAppPID, 0) != 0 && errno == ESRCH) {
        gActiveAppPID = 0;
        gActiveAppID = @"";
        activeAppPID = 0;
        activeAppID = @"";
    }
    os_unfair_lock_unlock(&gStateLock);

    NSString *startupPhaseCode = GUIStartStateValue(@"phase");
    if (startupActive)
        phase = StartupPhaseDisplay(startupPhaseCode);

    // macos_gui.sh runs its watchdog independently so it can still recover the
    // device if this daemon or the App disconnects. Surface its durable reason
    // through the typed status protocol instead of leaving the UI looking like
    // an unexplained WindowServer exit.
    NSString *safetyTrip = ReadSmallTextFile(kSafetyTrip, 1024);
    if (!ws && !busy && safetyTrip.length) {
        phase = @"安全保护已触发";
        lastError = safetyTrip;
    }

    xpc_dictionary_set_uint64(reply, "protocol_version", MACWS_CONTROL_VERSION);
    xpc_dictionary_set_bool(reply, "busy", busy);
    xpc_dictionary_set_bool(reply, "workspace_sleeping",
                            atomic_load(&gWorkspaceSleeping));
    xpc_dictionary_set_bool(reply, "startup_retry_available",
                            startupRetryAvailable);
    SetString(reply, "phase", phase);
    SetString(reply, "last_error", lastError);
    SetString(reply, "safety_trip", safetyTrip);
    xpc_dictionary_set_bool(reply, "rootfs_ready", RootFSReady());
    xpc_dictionary_set_bool(reply, "windowserver_running", ws);
    xpc_dictionary_set_int64(reply, "windowserver_pid", wsPID);
    xpc_dictionary_set_bool(reply, "input_running", inputJob && IsSocket(kInputSocket));
    xpc_dictionary_set_int64(reply, "input_pid", inputPID);
    xpc_dictionary_set_bool(reply, MACWS_CONTROL_KEY_SYSTEM_INPUT_READY,
                            systemInputReady);
    xpc_dictionary_set_int64(reply, MACWS_CONTROL_KEY_SYSTEM_INPUT_PID,
                             systemInputReady ? systemInputPID : 0);
    xpc_dictionary_set_int64(reply, "active_app_pid", activeAppPID);
    SetString(reply, "active_app_id", activeAppID);
    xpc_dictionary_set_bool(reply, "app_input_ready",
                            IsAppInputSocket(activeAppPID));
    xpc_dictionary_set_bool(reply, "frame_ready", frame);
    xpc_dictionary_set_uint64(reply, "frame_width", width);
    xpc_dictionary_set_uint64(reply, "frame_height", height);
    xpc_dictionary_set_uint64(reply, "frame_generation", frameGeneration);
    // Kept for older Host clients; production compatibility is built in and
    // is no longer represented as an experimental marker-file mode.
    xpc_dictionary_set_bool(reply, "experimental_mode", false);
    SetString(reply, "startup_log",
              (startupActive || startupRetryAvailable)
                  ? StartupLogText(startupBeganAt,
                                   [startupPhaseCode isEqualToString:@"trust"] ||
                                       startupRetryAvailable)
                  : @"");
    xpc_dictionary_set_bool(reply, "glassdemo_available", access("/var/mnt/rootfs/tmp/GlassDemo", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "terminal_available", access("/var/mnt/rootfs/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "activity_monitor_available", access("/var/mnt/rootfs/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "finder_available", access("/var/mnt/rootfs/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "system_settings_available",
        access("/var/mnt/rootfs/System/Applications/System Settings.app/Contents/MacOS/System Settings", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "maps_available",
        access("/var/mnt/rootfs/System/Applications/Maps.app/Contents/MacOS/Maps", X_OK) == 0);
    xpc_dictionary_set_bool(reply, "vscode_available",
        access("/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/MacOS/Electron", X_OK) == 0 &&
        access(kVSCodePlist, R_OK) == 0);
    xpc_dictionary_set_bool(reply, "amadine_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Amadine.app/Contents/MacOS/Amadine"));
    xpc_dictionary_set_bool(reply, "word_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word"));
    xpc_dictionary_set_bool(reply, "excel_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Microsoft Excel.app/Contents/MacOS/Microsoft Excel"));
    xpc_dictionary_set_bool(reply, "powerpoint_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Microsoft PowerPoint.app/Contents/MacOS/Microsoft PowerPoint"));
    xpc_dictionary_set_bool(reply, "weather_available", HasExecutableFileMode(
        "/var/mnt/rootfs/System/Applications/Weather.app/Contents/MacOS/Weather"));
    xpc_dictionary_set_bool(reply, "sublime_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Sublime Text.app/Contents/MacOS/sublime_text"));
    xpc_dictionary_set_bool(reply, "steam_available",
        access(kSteamPlist, R_OK) == 0 &&
        (HasExecutableFileMode(
             "/var/mnt/rootfs/Applications/Steam.app/Contents/MacOS/steam_osx") ||
         HasExecutableFileMode(
             "/var/mnt/rootfs/Users/root/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx")));
    xpc_dictionary_set_bool(reply, "asphalt_available", HasExecutableFileMode(
        "/var/mnt/rootfs/Applications/Asphalt.app/Contents/MacOS/Asphalt"));
}

static NSString *TailFile(const char *path, NSUInteger limit) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return @"";
    off_t end = lseek(fd, 0, SEEK_END);
    off_t start = end > (off_t)limit ? end - (off_t)limit : 0;
    (void)lseek(fd, start, SEEK_SET);
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(end - start)];
    ssize_t count = read(fd, data.mutableBytes, data.length);
    close(fd);
    if (count < 0) return @"";
    data.length = (NSUInteger)count;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

static void ReplyResult(xpc_object_t request, BOOL ok, NSString *message,
                        void (^extra)(xpc_object_t reply)) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!peer || !reply) return;
    xpc_dictionary_set_bool(reply, "ok", ok);
    SetString(reply, "message", message ?: @"");
    if (extra) extra(reply);
    xpc_connection_send_message(peer, reply);
}

// macOS Libinfo normally sends getaddrinfo requests to mDNSResponder.  The
// chroot has the Ventura client frameworks but not a viable resolver daemon in
// its bootstrap namespace, while this iOS-native daemon has the real network
// configuration and resolver service.  Preserve the standard getaddrinfo ABI
// across a small typed XPC request; callers reconstruct ordinary addrinfo
// nodes and keep the successful local macOS path untouched.
static void ReplyHostResolution(xpc_object_t request) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!peer || !reply) return;

    const char *node = xpc_dictionary_get_string(
        request, MACWS_CONTROL_KEY_DNS_NODE);
    const char *service = xpc_dictionary_get_string(
        request, MACWS_CONTROL_KEY_DNS_SERVICE);
    if (!node || node[0] == '\0' || strnlen(node, 254) > 253 ||
        (service && strnlen(service, 65) > 64)) {
        xpc_dictionary_set_int64(reply, "gai_error", EAI_NONAME);
        xpc_connection_send_message(peer, reply);
        return;
    }

    struct addrinfo hints = {0};
    hints.ai_flags = (int)xpc_dictionary_get_int64(
        request, MACWS_CONTROL_KEY_DNS_FLAGS);
    hints.ai_family = (int)xpc_dictionary_get_int64(
        request, MACWS_CONTROL_KEY_DNS_FAMILY);
    hints.ai_socktype = (int)xpc_dictionary_get_int64(
        request, MACWS_CONTROL_KEY_DNS_SOCKTYPE);
    hints.ai_protocol = (int)xpc_dictionary_get_int64(
        request, MACWS_CONTROL_KEY_DNS_PROTOCOL);
    if (hints.ai_family != AF_UNSPEC && hints.ai_family != AF_INET &&
        hints.ai_family != AF_INET6) {
        xpc_dictionary_set_int64(reply, "gai_error", EAI_FAMILY);
        xpc_connection_send_message(peer, reply);
        return;
    }

    struct addrinfo *resolved = NULL;
    int error = getaddrinfo(node, service && service[0] ? service : NULL,
                            &hints, &resolved);
    xpc_dictionary_set_int64(reply, "gai_error", error);
    if (error == 0) {
        xpc_object_t entries = xpc_array_create(NULL, 0);
        size_t count = 0;
        for (const struct addrinfo *item = resolved;
             item && count < 64; item = item->ai_next, count++) {
            if (!item->ai_addr || item->ai_addrlen == 0 ||
                item->ai_addrlen > sizeof(struct sockaddr_storage)) continue;
            xpc_object_t entry = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_int64(entry, "flags", item->ai_flags);
            xpc_dictionary_set_int64(entry, "family", item->ai_family);
            xpc_dictionary_set_int64(entry, "socktype", item->ai_socktype);
            xpc_dictionary_set_int64(entry, "protocol", item->ai_protocol);
            xpc_dictionary_set_data(entry, "address", item->ai_addr,
                                    item->ai_addrlen);
            if (item->ai_canonname)
                xpc_dictionary_set_string(entry, "canonname",
                                          item->ai_canonname);
            xpc_array_append_value(entries, entry);
        }
        xpc_dictionary_set_value(reply, "results", entries);
        freeaddrinfo(resolved);
    }
    xpc_connection_send_message(peer, reply);
}

static BOOL WaitForGUIComponents(NSTimeInterval timeout, int *wsPIDOut) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        int pid = 0;
        if (JobHasPID(kWindowServerLabel, &pid) &&
            JobHasPID(kInputLabel, NULL) &&
            JobHasPID(kDisplayLabel, NULL) &&
            IsSocket(kInputSocket) &&
            IsSocket(kVNCPointerProxySocket)) {
            if (wsPIDOut) *wsPIDOut = pid;
            return YES;
        }
        usleep(250000);
    }
    return NO;
}

static BOOL WaitForCapture(int wsPID, uint64_t generation,
                           NSTimeInterval timeout, BOOL *processExited) {
    if (processExited) *processExited = NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        if (kill(wsPID, 0) != 0 && errno == ESRCH) {
            if (processExited) *processExited = YES;
            return NO;
        }
        if (ReadCaptureAck(wsPID, generation, NULL) && ReadFrame(NULL, NULL))
            return YES;
        usleep(100000);
    }
    return NO;
}

static void RotateWindowServerLog(void) {
    NSString *previous = [@(kWindowServerLog) stringByAppendingString:@".previous"];
    (void)unlink(previous.fileSystemRepresentation);
    if (rename(kWindowServerLog, previous.fileSystemRepresentation) == 0)
        HostLog(@"rotated WindowServer log to %@", previous);
}

static BOOL StopGUI(NSString **message);

static BOOL StartGUI(BOOL experimental, NSString **message) {
    (void)experimental; // Legacy wire field; production adapters are mandatory.
    if (!RootFSReady()) {
        *message = @"macOS rootfs 或启动组件不完整";
        return NO;
    }
    RemovePath(kFrame);
    RemovePath(kCaptureFlag);
    RemovePath(kCaptureAck);
    RemovePath(kSafetyTrip);

    RotateWindowServerLog();
    SetState(YES, @"检查并修复启动环境…", @"");
    const char *startArgv[] = {kBash, kGUI, "start", "coexist",
                               "--no-terminal", "--no-vnc", NULL};
    int startupLogFD = open(kStartupLogPath,
                            O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (startupLogFD >= 0) close(startupLogFD);
    int rc = RunCommandToLog(startArgv, YES, kStartupLogPath);
    if (rc != 0) {
        *message = [NSString stringWithFormat:@"GUI 启动脚本失败（退出码 %d）", rc];
        return NO;
    }
    // The script has already loaded and validated WindowServer, inputd and
    // displayd.  In the native window architecture there is intentionally no
    // AppKit window yet (`--no-terminal --no-vnc`), so requiring a framebuffer
    // acknowledgement here creates a circular dependency: the user cannot
    // launch an app until a frame exists, while no frame can exist until an
    // app is launched.  Runtime-confirmed on 2026-07-31: all three services
    // remained healthy for a minute with a zero-window DisplayStream, then the
    // old 60-second capture deadline tore them down.  Establish workspace
    // readiness from the actual service endpoints, including OSXvnc's
    // localhost-only pointer proxy used for native Mission Control drags;
    // LaunchAllowedApp separately requires that process's real NSWindow
    // metrics before reporting success.
    SetState(YES, @"等待 WindowServer、触控与窗口流…", @"");
    int wsPID = 0;
    if (WaitForGUIComponents(15.0, &wsPID)) {
        *message = @"macOS 工作区、触控桥与窗口流已就绪";
        return YES;
    }

    HostLog(@"workspace endpoints unavailable after launcher success");
    NSString *stopMessage = nil;
    (void)StopGUI(&stopMessage);
    *message = @"macOS 工作区服务未能完成就绪，已安全停止";
    return NO;
}

static BOOL StopGUI(NSString **message) {
    const char *argv[] = {kBash, kGUI, "stop", NULL};
    int rc = RunCommand(argv, YES);
    const char *unloadUIKitSystem[] = {
        kLaunchctl, "unload", kUIKitSystemPlist, NULL,
    };
    (void)RunCommand(unloadUIKitSystem, YES);
    const char *appNames[] = {"GlassDemo", "Terminal", "Activity Monitor",
                              "Finder", "System Settings", "Maps",
                              "Amadine", "Microsoft Word", "Microsoft Excel",
                              "Microsoft PowerPoint",
                              "MacWSCatalystLauncher", "UIKitSystem"};
    for (NSUInteger i = 0; i < sizeof(appNames) / sizeof(appNames[0]); i++) {
        const char *killArgv[] = {kKillall, "-9", appNames[i], NULL};
        (void)RunCommand(killArgv, YES);
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = 0;
    gActiveAppID = @"";
    os_unfair_lock_unlock(&gStateLock);
    [gApplicationSessions removeAllObjects];
    gObservedOrphanOverlayPID = 0;
    gObservedOrphanOverlaySince = 0;
    gKnownSteamOverlayPID = 0;
    gKnownStrayPID = 0;
    gSteamProcessDiscoveryPrimed = NO;
    gSteamOwnerWasPresent = NO;
    gNextSteamProcessDiscovery = 0;
    RemovePath(kFrame);
    RemovePath(kCaptureFlag);
    RemovePath(kCaptureAck);
    if (rc != 0) {
        *message = [NSString stringWithFormat:@"停止脚本失败（退出码 %d）", rc];
        return NO;
    }
    *message = @"macOS GUI 已停止，iPadOS 保持运行";
    return YES;
}

typedef struct {
    const char *identifier;
    const char *rootPath;
    const char *logPath;
} AllowedApp;

static const AllowedApp kAllowedApps[] = {
    {"glassdemo", "/tmp/GlassDemo", "/var/mobile/Library/Logs/GlassDemo.host.log"},
    {"terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "/var/mobile/Library/Logs/Terminal.host.log"},
    {"activity-monitor", "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor", "/var/mobile/Library/Logs/ActivityMonitor.host.log"},
    {"finder", "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", "/var/mobile/Library/Logs/Finder.host.log"},
    {"system-settings", "/System/Applications/System Settings.app/Contents/MacOS/System Settings", "/var/mobile/Library/Logs/SystemSettings.host.log"},
    {"maps", "/System/Applications/Maps.app/Contents/MacOS/Maps", "/var/mobile/Library/Logs/Maps.host.log"},
    {"amadine", "/Applications/Amadine.app/Contents/MacOS/Amadine", "/var/mobile/Library/Logs/Amadine.host.log"},
    {"word", "/Applications/Microsoft Word.app/Contents/MacOS/Microsoft Word", "/var/mobile/Library/Logs/MicrosoftWord.host.log"},
    {"excel", "/Applications/Microsoft Excel.app/Contents/MacOS/Microsoft Excel", "/var/mobile/Library/Logs/MicrosoftExcel.host.log"},
    {"powerpoint", "/Applications/Microsoft PowerPoint.app/Contents/MacOS/Microsoft PowerPoint", "/var/mobile/Library/Logs/MicrosoftPowerPoint.host.log"},
    {"sublime", "/Applications/Sublime Text.app/Contents/MacOS/sublime_text", "/var/mobile/Library/Logs/SublimeText.host.log"},
};

static BOOL IsThirdPartyAppIdentifier(const char *identifier) {
    return identifier &&
        (strcmp(identifier, "amadine") == 0 ||
         strcmp(identifier, "word") == 0 ||
         strcmp(identifier, "excel") == 0 ||
         strcmp(identifier, "powerpoint") == 0 ||
         strcmp(identifier, "sublime") == 0);
}

// A native Host launch is complete when AppInputBridge has published at least
// one real NSWindow descriptor. This replaces the VNC framebuffer
// acknowledgement, which is intentionally absent from the localhost-only
// pointer-proxy job selected by `start --no-vnc`.
static uint64_t ReadWindowMetricsGeneration(pid_t pid) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path),
             "/var/mnt/rootfs/private/tmp/macws_window_metrics.%d.bin", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    MacWSWindowMetricsHeader header = {0};
    struct stat st = {0};
    ssize_t count = read(fd, &header, sizeof(header));
    BOOL valid = fstat(fd, &st) == 0 &&
        count == (ssize_t)sizeof(header) &&
        st.st_size >= (off_t)sizeof(header) &&
        MacWSWindowMetricsAreValid(&header, (size_t)st.st_size);
    close(fd);
    return valid ? header.generation : 0;
}

static BOOL WaitForWindowMetricsFlagsAfterGeneration(
        pid_t pid, NSTimeInterval timeout, uint32_t requiredFlags,
        uint64_t minimumGenerationExclusive, int *exitStatusOut) {
    char path[PATH_MAX];
    snprintf(path, sizeof(path),
             "/var/mnt/rootfs/private/tmp/macws_window_metrics.%d.bin", pid);
    // AppInputBridge removes this PID-scoped sidecar in the target process's
    // constructor before it starts publishing.  Removing it here races a
    // process that is already running (notably a reused VS Code launch): its
    // unchanged-window fast path would then have no reason to recreate the
    // file, turning a healthy window into a 30-second false timeout.
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        int status = 0;
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) {
            if (exitStatusOut) *exitStatusOut = status;
            return NO;
        }

        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            struct stat st = {0};
            MacWSWindowMetricsHeader header = {0};
            ssize_t count = read(fd, &header, sizeof(header));
            BOOL valid = fstat(fd, &st) == 0 &&
                count == (ssize_t)sizeof(header) &&
                st.st_size >= (off_t)sizeof(header) &&
                MacWSWindowMetricsAreValid(&header, (size_t)st.st_size);
            BOOL ready = NO;
            if (valid &&
                (minimumGenerationExclusive == 0 ||
                 header.generation > minimumGenerationExclusive)) {
                // NSApplication.windows retains ordered-out panels and other
                // invisible objects after the last user window closes.
                // Runtime-confirmed with Terminal after Scene discard: the
                // sidecar still had entries while displayd's validated
                // catalog had no window for that PID. A launch is reusable
                // only when at least one real AppKit window is visible.
                for (uint32_t index = 0; index < header.entryCount; index++) {
                    MacWSWindowMetricsEntry entry = {0};
                    off_t offset = (off_t)header.size +
                        (off_t)index * header.entrySize;
                    if (pread(fd, &entry, header.entrySize, offset) !=
                            (ssize_t)header.entrySize)
                        break;
                    if ((entry.flags & requiredFlags) == requiredFlags) {
                        ready = YES;
                        break;
                    }
                }
            }
            close(fd);
            if (ready) return YES;
        }
        usleep(100000);
    }
    return NO;
}

static BOOL WaitForWindowMetricsFlags(pid_t pid, NSTimeInterval timeout,
                                      uint32_t requiredFlags,
                                      int *exitStatusOut) {
    return WaitForWindowMetricsFlagsAfterGeneration(
        pid, timeout, requiredFlags, 0, exitStatusOut);
}

static BOOL WaitForWindowMetrics(pid_t pid, NSTimeInterval timeout,
                                 int *exitStatusOut) {
    return WaitForWindowMetricsFlags(pid, timeout,
                                     MacWSStreamWindowVisible,
                                     exitStatusOut);
}

// launchd reaps macwshostd itself, but a successfully launched macOS app is
// our direct child.  WaitForWindowMetrics owns waitpid only until the first
// real window is published; after that there was previously no waiter at all.
// Runtime witness on 2026-08-01: killed Terminal PID 6471 remained
// `Z <defunct>` with macwshostd as PPID, so later launch/reuse transactions
// accumulated stale process state.  Install one blocking waiter only after
// the initial-window transaction has finished, avoiding a race with its
// WNOHANG exit witness while guaranteeing every long-lived app is reaped.
static void BeginApplicationChildReaper(pid_t pid, NSString *identifier) {
    if (pid <= 1) return;
    NSString *identifierCopy = [identifier copy] ?: @"app";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        pid_t waited = 0;
        do {
            waited = waitpid(pid, &status, 0);
        } while (waited < 0 && errno == EINTR);
        if (waited == pid) {
            NSString *result = WIFEXITED(status)
                ? [NSString stringWithFormat:@"exit-%d", WEXITSTATUS(status)]
                : (WIFSIGNALED(status)
                    ? [NSString stringWithFormat:@"signal-%d", WTERMSIG(status)]
                    : [NSString stringWithFormat:@"status-%d", status]);
            HostLog(@"launch-app reaped id=%@ pid=%d result=%@",
                    identifierCopy, pid, result);
            dispatch_async(gControlQueue, ^{
                ApplicationSessionObservedExit(
                    pid, identifierCopy,
                    [@"waitpid:" stringByAppendingString:result]);
            });
        } else if (errno != ECHILD) {
            HostLog(@"launch-app reap-failed id=%@ pid=%d errno=%d (%s)",
                    identifierCopy, pid, errno, strerror(errno));
        }
    });
}

static BOOL WaitForAppInputEndpoint(pid_t pid, NSTimeInterval timeout) {
    if (pid <= 1) return NO;
    char path[PATH_MAX] = {0};
    int length = snprintf(path, sizeof(path),
        "/var/mnt/rootfs/private/tmp/macws_app_input.%d.sock", pid);
    if (length <= 0 || (size_t)length >= sizeof(path)) return NO;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        if (access(path, F_OK) == 0) return YES;
        if (kill(pid, 0) != 0 && errno == ESRCH) return NO;
        usleep(50000);
    }
    return NO;
}

// Race two real readiness witnesses instead of withholding the launch event
// for three seconds: a window may already exist, otherwise send exactly one
// native reopen as soon as the target's input endpoint has been published.
// Runtime-confirmed 2026-09-12: Excel 21855, PowerPoint 23558 and Sublime
// 23729 waited ~3.05 s before application-reopen was sent. No visible metrics
// or protocol checks are relaxed by this admission policy.
static BOOL WaitForInitialApplicationWindow(pid_t pid, NSTimeInterval timeout,
                                            int *exitStatusOut);

static BOOL SendAppInputRecord(pid_t pid, MacWSInputRecord *record,
                               int *errorOut) {
    if (pid <= 1 || !record) {
        if (errorOut) *errorOut = EINVAL;
        return NO;
    }
    int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (socketFD < 0) {
        if (errorOut) *errorOut = errno;
        return NO;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    int length = snprintf(address.sun_path, sizeof(address.sun_path),
        "/var/mnt/rootfs/private/tmp/macws_app_input.%d.sock", pid);
    if (length <= 0 || (size_t)length >= sizeof(address.sun_path)) {
        close(socketFD);
        if (errorOut) *errorOut = ENAMETOOLONG;
        return NO;
    }
    record->targetPID = pid;
    record->version = MacWSInputWireVersionForKind(record->kind);
    ssize_t sent = sendto(socketFD, record, sizeof(*record), 0,
        (const struct sockaddr *)&address, sizeof(address));
    int savedError = sent < 0 ? errno :
        (sent == (ssize_t)sizeof(*record) ? 0 : EMSGSIZE);
    close(socketFD);
    if (errorOut) *errorOut = savedError;
    return savedError == 0;
}

// Finder launched as a chroot executable reaches NSApplication's ordinary
// event loop but does not create a browser window by itself. Runtime evidence
// on 2026-08-01: PID 1400 kept a valid zero-entry metrics sidecar for 30 s,
// while its AppInputBridge endpoint was live and the process stayed healthy.
// Ask that exact AppKit process to resolve and perform its standard enabled
// Command-N menu target/action, then require a visible-window metrics witness.
// This is the missing launch action, not a synthetic window or uptime check.
static BOOL RequestFinderBrowserWindow(pid_t pid, NSTimeInterval timeout) {
    if (!WaitForAppInputEndpoint(pid, MIN(timeout, 5.0))) {
        HostLog(@"finder-bootstrap pid=%d result=no-appinput-endpoint", pid);
        return NO;
    }
    static _Atomic uint32_t sampleSequence = 0;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindCreateInitialWindow,
        .x = 0.0f,
        .y = 0.0f,
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = pid,
        .source = MacWSInputSourceUnknown,
        .sampleSequence = atomic_fetch_add(&sampleSequence, 1) + 1,
    };
    int sendError = 0;
    BOOL sent = SendAppInputRecord(pid, &record, &sendError);
    HostLog(@"finder-bootstrap pid=%d action=appkit-command-n sent=%@ "
            "errno=%d", pid, sent ? @"YES" : @"NO", sendError);
    if (!sent) return NO;
    int exitStatus = -1;
    BOOL ready = WaitForWindowMetrics(pid, timeout, &exitStatus);
    HostLog(@"finder-bootstrap pid=%d result=%@ exit-status=%d", pid,
            ready ? @"window-ready" : @"no-visible-window", exitStatus);
    return ready;
}

// Apps launched by launchdchrootexec have a valid AppKit event loop,
// HIServices process record and real NSWindows, but launchservicesd cannot
// create their AppleEvent endpoint (runtime: both PID and ProcessSerialNumber
// kAEReopenApplication sends return procNotFound/-600).  System Settings is a
// concrete witness: its SwiftUI delegate creates an ordered-out settings scene
// at (239,87,715x625), then waits for the ordinary reopen lifecycle before
// ordering it on screen. Deliver that exact public NSApplicationDelegate
// lifecycle inside the owning process and require a visible metrics entry.
static BOOL RequestApplicationReopen(pid_t pid, NSTimeInterval timeout) {
    if (!WaitForAppInputEndpoint(pid, MIN(timeout, 5.0))) {
        HostLog(@"application-reopen pid=%d result=no-appinput-endpoint", pid);
        return NO;
    }
    uint64_t previousGeneration = ReadWindowMetricsGeneration(pid);
    static _Atomic uint32_t sampleSequence = 0;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindReopenApplication,
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = pid,
        .source = MacWSInputSourceUnknown,
        .sampleSequence = atomic_fetch_add(&sampleSequence, 1) + 1,
    };
    int sendError = 0;
    BOOL sent = SendAppInputRecord(pid, &record, &sendError);
    HostLog(@"application-reopen pid=%d sent=%@ errno=%d",
            pid, sent ? @"YES" : @"NO", sendError);
    if (!sent) return NO;
    int exitStatus = -1;
    BOOL ready = WaitForWindowMetricsFlagsAfterGeneration(
        pid, timeout, MacWSStreamWindowVisible, previousGeneration,
        &exitStatus);
    HostLog(@"application-reopen pid=%d result=%@ previous-generation=%llu "
            "current-generation=%llu exit-status=%d", pid,
            ready ? @"window-ready" : @"no-visible-window",
            (unsigned long long)previousGeneration,
            (unsigned long long)ReadWindowMetricsGeneration(pid), exitStatus);
    return ready;
}

static BOOL WaitForInitialApplicationWindow(pid_t pid, NSTimeInterval timeout,
                                            int *exitStatusOut) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    char endpoint[PATH_MAX];
    snprintf(endpoint, sizeof(endpoint),
        "/var/mnt/rootfs/private/tmp/macws_app_input.%d.sock", pid);
    while (CFAbsoluteTimeGetCurrent() < deadline) {
        NSTimeInterval remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (WaitForWindowMetrics(pid, MIN(remaining, 0.05), exitStatusOut))
            return YES;
        if (exitStatusOut && *exitStatusOut >= 0) return NO;
        if (IsSocket(endpoint)) {
            remaining = deadline - CFAbsoluteTimeGetCurrent();
            if (remaining <= 0) return NO;
            HostLog(@"launch-app lifecycle-ready pid=%d route=endpoint-driven-reopen", pid);
            return RequestApplicationReopen(pid, remaining);
        }
    }
    return NO;
}

// Return a live, real Ventura Settings UI extension. System Settings persists
// the selected pane, so Appearance is not a valid universal readiness proxy:
// after reopening on Displays, Bluetooth, etc. the shell is healthy while the
// Appearance executable is correctly absent. Match the exact stock extension
// point in the appex's Info.plist as well as its strict on-disk executable
// path; an unrelated ExtensionKit child cannot satisfy this witness.
static pid_t FindRunningSettingsExtension(NSString **executableOut) {
    typedef int (*MacWSProcListPIDs)(uint32_t, uint32_t, void *, int);
    typedef int (*MacWSProcPIDPath)(int, void *, uint32_t);
    static MacWSProcListPIDs procListPIDs;
    static MacWSProcPIDPath procPIDPath;
    static dispatch_once_t procOnce;
    dispatch_once(&procOnce, ^{
        procListPIDs = (MacWSProcListPIDs)dlsym(
            RTLD_DEFAULT, "proc_listpids");
        procPIDPath = (MacWSProcPIDPath)dlsym(
            RTLD_DEFAULT, "proc_pidpath");
    });
    if (!procListPIDs || !procPIDPath) return 0;

    int capacity = procListPIDs(1 /* PROC_ALL_PIDS */, 0, NULL, 0);
    if (capacity <= 0) return 0;
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids) return 0;
    int bytes = procListPIDs(1, 0, pids, capacity);
    int count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    NSString *const rootPrefix = @"/System/Library/ExtensionKit/Extensions/";
    NSString *const hostPrefix =
        @"/var/mnt/rootfs/System/Library/ExtensionKit/Extensions/";
    NSString *const privateHostPrefix =
        @"/private/var/mnt/rootfs/System/Library/ExtensionKit/Extensions/";
    NSString *const executableMarker = @".appex/Contents/MacOS/";
    pid_t found = 0;
    for (int index = 0; index < count; index++) {
        pid_t pid = pids[index];
        if (pid <= 1 || pid == getpid()) continue;
        char processPath[4096] = {0};
        if (procPIDPath(pid, processPath, sizeof(processPath)) <= 0)
            continue;
        NSString *candidate = [NSString stringWithUTF8String:processPath];
        NSString *rootPath = nil;
        if ([candidate hasPrefix:rootPrefix]) {
            rootPath = candidate;
        } else if ([candidate hasPrefix:hostPrefix] ||
                   [candidate hasPrefix:privateHostPrefix]) {
            rootPath = [candidate substringFromIndex:
                [candidate hasPrefix:privateHostPrefix]
                    ? @"/private/var/mnt/rootfs".length
                    : @"/var/mnt/rootfs".length];
        } else {
            continue;
        }
        if ([rootPath containsString:@".."] ||
            ![rootPath containsString:executableMarker] ||
            [rootPath hasSuffix:executableMarker]) continue;
        NSRange marker = [rootPath rangeOfString:executableMarker];
        if (marker.location == NSNotFound) continue;
        NSUInteger appexEnd = marker.location + @".appex".length;
        NSString *bundleRoot = [rootPath substringToIndex:appexEnd];
        NSString *infoPath = [@"/var/mnt/rootfs"
            stringByAppendingFormat:@"%@/Contents/Info.plist", bundleRoot];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
            infoPath];
        NSDictionary *attributes = [info[@"EXAppExtensionAttributes"]
            isKindOfClass:NSDictionary.class]
                ? info[@"EXAppExtensionAttributes"] : nil;
        NSString *extensionPoint = [attributes[@"EXExtensionPointIdentifier"]
            isKindOfClass:NSString.class]
                ? attributes[@"EXExtensionPointIdentifier"] : nil;
        if (![extensionPoint isEqualToString:
                @"com.apple.Settings.extension.ui"]) continue;
        if (kill(pid, 0) != 0 && errno != EPERM) continue;
        found = pid;
        if (executableOut) *executableOut = rootPath;
        break;
    }
    free(pids);
    return found;
}

// System Settings' SwiftUI shell can publish a real visible NSWindow before
// ExtensionKit has supplied the selected remote preference pane. Require both
// halves of the stock transaction: a fresh shell-window generation
// (RequestApplicationReopen above) and one real, metadata-validated Ventura
// Settings extension executable launched by ExtensionKit. This does not
// synthesize content or convert an extension error into success.
static BOOL WaitForSystemSettingsContent(NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        NSString *executable = nil;
        pid_t extensionPID = FindRunningSettingsExtension(&executable);
        if (extensionPID > 1) {
            HostLog(@"system-settings content result=settings-extension-ready "
                    "pid=%d executable=%@", extensionPID, executable);
            return YES;
        }
        usleep(100000);
    } while (deadline.timeIntervalSinceNow > 0);
    HostLog(@"system-settings content result=missing-settings-extension");
    return NO;
}

static off_t FileSizeAtPath(const char *path) {
    struct stat st = {0};
    return stat(path, &st) == 0 && st.st_size > 0 ? st.st_size : 0;
}

// Associate Electron's own renderer-health diagnostics with one launch.  The
// production log is append-only, so a byte boundary avoids both stale alerts
// from a prior PID and assumptions about wall-clock/time-zone formatting.
static void WriteVSCodeHealthMarker(pid_t pid, off_t logOffset) {
    char value[96];
    int length = snprintf(value, sizeof(value), "%d %lld\n", pid,
                          (long long)MAX(logOffset, (off_t)0));
    int fd = open(kVSCodeHealthMarker,
                  O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return;
    (void)write(fd, value, (size_t)length);
    close(fd);
}

static BOOL ReadVSCodeHealthMarker(pid_t *pidOut, off_t *logOffsetOut) {
    char value[96] = {0};
    int fd = open(kVSCodeHealthMarker, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    int pid = 0;
    long long offset = 0;
    if (count <= 0 || sscanf(value, "%d %lld", &pid, &offset) != 2 ||
        pid <= 1 || offset < 0)
        return NO;
    if (pidOut) *pidOut = (pid_t)pid;
    if (logOffsetOut) *logOffsetOut = (off_t)offset;
    return YES;
}

static BOOL VSCodeLogContainsNeedleAfter(off_t startOffset,
                                         const char *needle) {
    if (!needle || !*needle) return NO;
    const NSUInteger needleLength = strlen(needle);
    const NSUInteger overlap = needleLength > 0 ? needleLength - 1 : 0;
    int fd = open(kVSCodeLog, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat st = {0};
    if (fstat(fd, &st) != 0 || startOffset < 0 || startOffset > st.st_size) {
        close(fd);
        return NO;
    }
    if (lseek(fd, startOffset, SEEK_SET) < 0) {
        close(fd);
        return NO;
    }
    NSData *needleData = [NSData dataWithBytes:needle length:needleLength];
    NSMutableData *window = [NSMutableData data];
    uint8_t buffer[32768];
    for (;;) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count > 0) {
            [window appendBytes:buffer length:(NSUInteger)count];
            if ([window rangeOfData:needleData options:0
                              range:NSMakeRange(0, window.length)].location !=
                    NSNotFound) {
                close(fd);
                return YES;
            }
            if (window.length > overlap) {
                NSData *tail = [window subdataWithRange:
                    NSMakeRange(window.length - overlap, overlap)];
                [window setData:tail];
            }
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
    close(fd);
    return NO;
}

static BOOL VSCodeLogContainsUnresponsiveAfter(off_t startOffset) {
    return VSCodeLogContainsNeedleAfter(
        startOffset, "CodeWindow: detected unresponsive");
}

static BOOL VSCodeLogContainsCommandBufferFailureAfter(off_t startOffset) {
    return VSCodeLogContainsNeedleAfter(
        startOffset, "Completed MTLCommandBuffer failed, and error is "
                     "Internal Error");
}

// Return an already-running instance of this exact chroot executable. App
// identity is the resolved executable path, not a display name or p_comm:
// those can collide and would make a different application steal the Scene.
// proc_pidpath may expose either the process's chroot-relative macOS path or
// the iOS host path, depending on which kernel image supplied the caller.
static pid_t FindRunningRootExecutable(NSString *rootPath) {
    if (!rootPath.length) return 0;
    typedef int (*MacWSProcListPIDs)(uint32_t, uint32_t, void *, int);
    typedef int (*MacWSProcPIDPath)(int, void *, uint32_t);
    static MacWSProcListPIDs procListPIDs;
    static MacWSProcPIDPath procPIDPath;
    static dispatch_once_t procOnce;
    dispatch_once(&procOnce, ^{
        procListPIDs = (MacWSProcListPIDs)dlsym(
            RTLD_DEFAULT, "proc_listpids");
        procPIDPath = (MacWSProcPIDPath)dlsym(
            RTLD_DEFAULT, "proc_pidpath");
    });
    if (!procListPIDs || !procPIDPath) return 0;
    NSString *hostPath = [@("/var/mnt/rootfs")
        stringByAppendingString:rootPath];
    char canonicalHostPath[PATH_MAX] = {0};
    if (realpath(hostPath.fileSystemRepresentation, canonicalHostPath)) {
        hostPath = [NSString stringWithUTF8String:canonicalHostPath];
    }
    const uint32_t allPIDs = 1; // PROC_ALL_PIDS from Darwin libproc.h
    int capacity = procListPIDs(allPIDs, 0, NULL, 0);
    if (capacity <= 0) return 0;
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids) return 0;
    int bytes = procListPIDs(allPIDs, 0, pids, capacity);
    int count = bytes > 0 ? bytes / (int)sizeof(pid_t) : 0;
    pid_t found = 0;
    for (int index = 0; index < count; index++) {
        pid_t pid = pids[index];
        if (pid <= 1 || pid == getpid()) continue;
        char processPath[4096] = {0};
        if (procPIDPath(pid, processPath, sizeof(processPath)) <= 0)
            continue;
        NSString *candidate = [NSString stringWithUTF8String:processPath];
        if (![candidate isEqualToString:rootPath] &&
            ![candidate isEqualToString:hostPath]) continue;
        if (kill(pid, 0) == 0 || errno == EPERM) {
            found = pid;
            break;
        }
    }
    free(pids);
    return found;
}

// Observe the target's exit without mutating Dock. Runtime log
// 1788447667.111..1788447668.038 proves the old "refresh" implementation sent
// SIGTERM to healthy Dock PID 72537 after VS Code PID 65948 had already exited,
// then waited for Dock PID 54080. That compatibility repair was the reported
// Dock restart; process exit is not authority to tear down Dock's menus,
// Spaces, or unrelated application state. The still-missing LaunchServices
// termination notification remains a separately labelled compatibility gap.
static BOOL RefreshDockAfterProcessExit(pid_t targetPID, NSString **message) {
    if (targetPID <= 1) {
        *message = @"缺少有效的应用进程标识，Dock 未改动";
        return NO;
    }
    NSDate *exitDeadline = [NSDate dateWithTimeIntervalSinceNow:0.65];
    while (exitDeadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(targetPID, 0) != 0 && errno == ESRCH) break;
        usleep(50000);
    }
    errno = 0;
    if (kill(targetPID, 0) == 0 || errno != ESRCH) {
        HostLog(@"dock-refresh skipped target=%d reason=still-running",
                targetPID);
        *message = [NSString stringWithFormat:
            @"应用 PID %d 仍在运行，未重建 Dock 状态", targetPID];
        return YES;
    }

    HostLog(@"dock-refresh target=%d result=preserved "
            "compatibility-gap=launchservices-termination-notification",
            targetPID);
    *message = @"应用已退出；Dock 保持运行";
    return YES;
}

static NSString *RootExecutablePathForPID(pid_t pid) {
    if (pid <= 1) return nil;
    typedef int (*MacWSProcPIDPath)(int, void *, uint32_t);
    static MacWSProcPIDPath procPIDPath;
    static dispatch_once_t procOnce;
    dispatch_once(&procOnce, ^{
        procPIDPath = (MacWSProcPIDPath)dlsym(
            RTLD_DEFAULT, "proc_pidpath");
    });
    if (!procPIDPath) return nil;
    char processPath[PATH_MAX] = {0};
    if (procPIDPath(pid, processPath, sizeof(processPath)) <= 0) return nil;
    NSString *path = [NSString stringWithUTF8String:processPath];
    // proc_pidpath() canonicalizes the bind-mounted macOS root differently
    // across iOS vnode generations. Runtime-confirmed on 2026-08-22: the
    // VS Code PID 61312 resolved through `/private/var/mnt/rootfs/...`, while
    // the supervisor had stored `/Applications/...`; treating those as two
    // identities produced a false exit one second after a healthy launch.
    // Strip either spelling before comparing the executable identity.
    static NSArray<NSString *> *hostRoots;
    static dispatch_once_t rootsOnce;
    dispatch_once(&rootsOnce, ^{
        hostRoots = @[@"/private/var/mnt/rootfs", @"/var/mnt/rootfs"];
    });
    for (NSString *hostRoot in hostRoots) {
        if (![path hasPrefix:[hostRoot stringByAppendingString:@"/"]])
            continue;
        path = [path substringFromIndex:hostRoot.length];
        break;
    }
    // Runtime-confirmed by MacWSHostd.log at 1787515957.282: a rootless
    // native executable launched through `/var/jb/usr/...` is reported by
    // proc_pidpath as
    // `/private/preboot/<hash>/dopamine-*/procursus/usr/...`.  Normalize the
    // real rootless mount to its stable public alias before applying exact
    // executable allowlists.  Require both the private-preboot root and the
    // `/procursus/` component so an unrelated path containing that word
    // cannot acquire a native-service identity.
    if ([path hasPrefix:@"/private/preboot/"]) {
        NSRange procursus = [path rangeOfString:@"/procursus/"];
        if (procursus.location != NSNotFound) {
            NSString *suffix = [path substringFromIndex:
                NSMaxRange(procursus) - 1];
            path = [@"/var/jb" stringByAppendingString:suffix];
        }
    }
    return path;
}

static BOOL QueryScreenLocked(BOOL *knownOut) {
    typedef mach_port_t (*MacWSSpringBoardPort)(void);
    // SpringBoardServices declares both output slots as Objective-C BOOL.
    // Keep the dynamically-resolved ABI exact instead of relying on C bool
    // happening to share its current one-byte representation.
    typedef void (*MacWSScreenLockStatus)(mach_port_t, BOOL *, BOOL *);
    static MacWSSpringBoardPort serverPort;
    static MacWSScreenLockStatus lockStatus;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *springboard = dlopen(
            "/System/Library/PrivateFrameworks/"
            "SpringBoardServices.framework/SpringBoardServices",
            RTLD_NOW | RTLD_LOCAL);
        if (!springboard) return;
        serverPort = (MacWSSpringBoardPort)dlsym(
            springboard, "SBSSpringBoardServerPort");
        lockStatus = (MacWSScreenLockStatus)dlsym(
            springboard, "SBGetScreenLockStatus");
    });
    if (!serverPort || !lockStatus) {
        if (knownOut) *knownOut = NO;
        return NO;
    }
    BOOL locked = NO;
    BOOL passcodeEnabled = NO;
    mach_port_t port = serverPort();
    if (port == MACH_PORT_NULL) {
        if (knownOut) *knownOut = NO;
        return NO;
    }
    lockStatus(port, &locked, &passcodeEnabled);
    if (knownOut) *knownOut = YES;
    return locked;
}

static void SetWorkspaceSleepMarker(BOOL sleeping) {
    if (!sleeping) {
        if (unlink(MACWS_WORKSPACE_SLEEP_MARKER_HOST) != 0 && errno != ENOENT)
            HostLog(@"workspace-power marker-remove errno=%d", errno);
        return;
    }
    int descriptor = open(MACWS_WORKSPACE_SLEEP_MARKER_HOST,
                          O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC |
                              O_NOFOLLOW,
                          0644);
    if (descriptor < 0) {
        HostLog(@"workspace-power marker-create errno=%d", errno);
        return;
    }
    const char state[] = "sleeping\n";
    ssize_t written = write(descriptor, state, sizeof(state) - 1);
    int writeError = errno;
    close(descriptor);
    if (written != (ssize_t)(sizeof(state) - 1)) {
        HostLog(@"workspace-power marker-write errno=%d", writeError);
        (void)unlink(MACWS_WORKSPACE_SLEEP_MARKER_HOST);
    }
}

static void SignalWorkspaceDisplayWake(void) {
    int descriptor = socket(AF_UNIX, SOCK_DGRAM, 0);
    if (descriptor < 0) return;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    address.sun_len = sizeof(address);
    strlcpy(address.sun_path,
            "/var/mnt/rootfs" MACWS_INTERACTION_WAKE_SOCKET_PATH,
            sizeof(address.sun_path));
    const uint8_t token = 1;
    (void)sendto(descriptor, &token, sizeof(token), MSG_DONTWAIT,
                 (const struct sockaddr *)&address, sizeof(address));
    close(descriptor);
}

static void AddWorkspaceProcessAndDescendants(
        NSMutableDictionary<NSNumber *, NSDictionary *> *processes,
        pid_t rootPID, NSString *source) {
    if (rootPID <= 1 || rootPID == getpid()) return;
    typedef int (*MacWSProcListChildPIDs)(pid_t, void *, int);
    static MacWSProcListChildPIDs listChildren;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        listChildren = (MacWSProcListChildPIDs)dlsym(
            RTLD_DEFAULT, "proc_listchildpids");
    });

    NSMutableArray<NSNumber *> *pending =
        [NSMutableArray arrayWithObject:@(rootPID)];
    for (NSUInteger cursor = 0; cursor < pending.count && cursor < 2048;
         cursor++) {
        pid_t pid = (pid_t)pending[cursor].intValue;
        NSNumber *key = @(pid);
        if (processes[key] || pid <= 1 || pid == getpid()) continue;
        NSString *path = RootExecutablePathForPID(pid);
        if (!path.length) continue;
        errno = 0;
        if (kill(pid, 0) != 0 && errno == ESRCH) continue;
        processes[key] = @{
            @"pid": key,
            @"path": path,
            @"source": source ?: @"workspace",
        };
        if (!listChildren) continue;
        pid_t children[512] = {0};
        int childCount = listChildren(pid, children, sizeof(children));
        if (childCount <= 0) continue;
        childCount = MIN(childCount,
                         (int)(sizeof(children) / sizeof(children[0])));
        for (int index = 0; index < childCount; index++) {
            if (children[index] > 1)
                [pending addObject:@(children[index])];
        }
    }
}

static NSArray<NSDictionary *> *CollectWorkspaceApplicationProcesses(void) {
    NSMutableDictionary<NSNumber *, NSDictionary *> *processes =
        [NSMutableDictionary dictionary];

    // These jobs are the visible Aqua applications, not the chroot's service
    // plane. WindowServer sleeps at its display-completion boundary; the
    // service daemons remain available so hostd can always wake the session.
    static NSSet<NSString *> *applicationLabels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        applicationLabels = [NSSet setWithArray:@[
            @"com.macwsguide.finder-desktop",
            @"com.macwsguide.dock",
            @"com.macwsguide.systemuiserver",
            @"com.macwsguide.controlcenter",
            @"UIKitApplication:com.macwsguide.terminal",
            @"UIKitApplication:com.macwsguide.osxvnc",
            @"UIKitApplication:com.macwsguide.vscode",
            @"UIKitApplication:com.macwsguide.steam",
            @"UIKitApplication:com.macwsguide.geekbench",
            @"UIKitApplication:com.macwsguide.chrome150",
            @"com.macwsguide.systemsettings",
            @"com.macwsguide.glassdemo",
        ]];
    });
    const char *argv[] = {kLaunchctl, "list", NULL};
    NSString *snapshot = CaptureCommand(argv, 128 * 1024);
    for (NSString *line in [snapshot componentsSeparatedByCharactersInSet:
             NSCharacterSet.newlineCharacterSet]) {
        NSArray<NSString *> *columns = [line componentsSeparatedByString:@"\t"];
        if (columns.count < 3) continue;
        pid_t pid = (pid_t)[columns[0] intValue];
        NSString *label = columns[2];
        if (pid <= 1 || ![applicationLabels containsObject:label]) continue;
        AddWorkspaceProcessAndDescendants(processes, pid, label);
    }

    for (NSDictionary *session in gApplicationSessions.allValues) {
        pid_t pid = (pid_t)[session[@"pid"] intValue];
        NSString *identifier = session[@"identifier"] ?: @"application";
        AddWorkspaceProcessAndDescendants(processes, pid, identifier);
    }
    if (gActiveAppPID > 1)
        AddWorkspaceProcessAndDescendants(
            processes, gActiveAppPID, gActiveAppID ?: @"active-application");

    return [processes.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSInteger leftPID = [left[@"pid"] integerValue];
            NSInteger rightPID = [right[@"pid"] integerValue];
            if (leftPID < rightPID) return NSOrderedAscending;
            if (leftPID > rightPID) return NSOrderedDescending;
            return NSOrderedSame;
        }];
}

static void PersistSuspendedWorkspaceProcesses(
        NSArray<NSDictionary *> *processes) {
    if (processes.count == 0) {
        (void)unlink(kWorkspaceSleepState);
        return;
    }
    if (![processes writeToFile:@(kWorkspaceSleepState) atomically:YES])
        HostLog(@"workspace-power state-write failed path=%s",
                kWorkspaceSleepState);
}

static NSArray<NSDictionary *> *LoadSuspendedWorkspaceProcesses(void) {
    NSArray *stored = [NSArray arrayWithContentsOfFile:@(kWorkspaceSleepState)];
    if (![stored isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *validated = [NSMutableArray array];
    for (id item in stored) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSNumber *pid = item[@"pid"];
        NSString *path = item[@"path"];
        if (![pid isKindOfClass:NSNumber.class] ||
            ![path isKindOfClass:NSString.class] ||
            pid.intValue <= 1 || !path.length) continue;
        [validated addObject:item];
    }
    return validated;
}

static void ResumeWorkspaceApplications(void) {
    NSArray<NSDictionary *> *processes = gSuspendedWorkspaceProcesses;
    if (processes.count == 0)
        processes = LoadSuspendedWorkspaceProcesses();
    NSUInteger resumed = 0;
    for (NSDictionary *entry in processes.reverseObjectEnumerator) {
        pid_t pid = (pid_t)[entry[@"pid"] intValue];
        NSString *expectedPath = entry[@"path"];
        NSString *currentPath = RootExecutablePathForPID(pid);
        if (![currentPath isEqualToString:expectedPath]) {
            HostLog(@"workspace-power resume-skip pid=%d expected=%@ actual=%@",
                    pid, expectedPath, currentPath ?: @"<absent>");
            continue;
        }
        if (kill(pid, SIGCONT) == 0) resumed++;
    }
    gSuspendedWorkspaceProcesses = nil;
    (void)unlink(kWorkspaceSleepState);
    HostLog(@"workspace-power applications-resumed count=%lu",
            (unsigned long)resumed);
}

static void ApplyWorkspacePowerState(BOOL sleeping, NSString *witness) {
    BOOL staleSleepState = !sleeping &&
        (access(MACWS_WORKSPACE_SLEEP_MARKER_HOST, F_OK) == 0 ||
         access(kWorkspaceSleepState, F_OK) == 0);
    if (atomic_load(&gWorkspaceSleeping) == sleeping && !staleSleepState)
        return;
    gWorkspaceSleeping = sleeping;
    uint64_t generation = ++gWorkspacePowerGeneration;
    if (sleeping) {
        SetWorkspaceSleepMarker(YES);
        notify_post(MACWS_WORKSPACE_WILL_SLEEP_NOTIFY);
        HostLog(@"workspace-power transition=sleep generation=%llu witness=%@",
                (unsigned long long)generation, witness);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                       gControlQueue, ^{
            if (!gWorkspaceSleeping ||
                generation != gWorkspacePowerGeneration) return;
            NSArray<NSDictionary *> *processes =
                CollectWorkspaceApplicationProcesses();
            NSMutableArray<NSDictionary *> *suspended =
                [NSMutableArray arrayWithCapacity:processes.count];
            for (NSDictionary *entry in processes) {
                pid_t pid = (pid_t)[entry[@"pid"] intValue];
                NSString *expectedPath = entry[@"path"];
                NSString *currentPath = RootExecutablePathForPID(pid);
                // Collection walks a live process tree. Revalidate the exact
                // executable immediately before the signal so an exited PID
                // cannot be recycled into an unrelated native process during
                // the short notification grace interval.
                if (![currentPath isEqualToString:expectedPath]) {
                    HostLog(@"workspace-power suspend-skip pid=%d expected=%@ actual=%@",
                            pid, expectedPath,
                            currentPath ?: @"<absent>");
                    continue;
                }
                if (kill(pid, SIGSTOP) == 0) [suspended addObject:entry];
            }
            gSuspendedWorkspaceProcesses = suspended.copy;
            PersistSuspendedWorkspaceProcesses(gSuspendedWorkspaceProcesses);
            HostLog(@"workspace-power applications-suspended count=%lu",
                    (unsigned long)gSuspendedWorkspaceProcesses.count);
        });
        return;
    }

    SetWorkspaceSleepMarker(NO);
    SignalWorkspaceDisplayWake();
    ResumeWorkspaceApplications();
    notify_post(MACWS_WORKSPACE_DID_WAKE_NOTIFY);
    HostLog(@"workspace-power transition=wake generation=%llu witness=%@",
            (unsigned long long)generation, witness);
}

static void EvaluateWorkspacePowerState(NSString *witness) {
    BOOL known = NO;
    BOOL locked = QueryScreenLocked(&known);
    if (!known) {
        HostLog(@"workspace-power state=unknown witness=%@", witness);
        return;
    }
    ApplyWorkspacePowerState(locked, witness);
}

static void StartWorkspacePowerCoordinator(void) {
    uint32_t lockResult = notify_register_dispatch(
        "com.apple.springboard.lockstate", &gLockStateToken, gControlQueue,
        ^(int token) {
            (void)token;
            EvaluateWorkspacePowerState(@"springboard-lockstate");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           gControlQueue, ^{
                EvaluateWorkspacePowerState(@"springboard-lockstate-settled");
            });
        });
    uint32_t blankResult = notify_register_dispatch(
        "com.apple.springboard.hasBlankedScreen", &gScreenBlankToken,
        gControlQueue, ^(int token) {
            (void)token;
            EvaluateWorkspacePowerState(@"springboard-screen-blank");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         250 * NSEC_PER_MSEC),
                           gControlQueue, ^{
                EvaluateWorkspacePowerState(@"springboard-screen-blank-settled");
            });
        });
    HostLog(@"workspace-power coordinator-ready lock-notify=%u blank-notify=%u",
            lockResult, blankResult);
    dispatch_async(gControlQueue, ^{
        EvaluateWorkspacePowerState(@"hostd-startup");
    });
}

// Steam is one user-visible application session split across processes:
// steam_osx owns the launchd job and lifetime, while its direct, argument-free
// Steam Helper child owns the AppKit window and AppInputBridge endpoint.  Do
// not scan by process name: CEF renderer/GPU helpers have the same executable,
// and a helper left by a different Steam generation must not satisfy launch.
static pid_t FindSteamUIProcess(pid_t steamPID, BOOL requireVisibleWindow) {
    if (steamPID <= 1) return 0;
    typedef int (*MacWSProcListChildPIDs)(pid_t, void *, int);
    static MacWSProcListChildPIDs procListChildPIDs;
    static dispatch_once_t procOnce;
    dispatch_once(&procOnce, ^{
        procListChildPIDs = (MacWSProcListChildPIDs)dlsym(
            RTLD_DEFAULT, "proc_listchildpids");
    });
    if (!procListChildPIDs) return 0;

    pid_t children[512] = {0};
    // Runtime-confirmed on iPadOS 16.3 on 2026-08-22: for Steam PID 22860,
    // proc_listchildpids returned 36 PID entries (not a byte count), including
    // direct UI owner 23268.  A fixed, bounded buffer avoids the API's NULL
    // sizing result, which describes global capacity rather than this parent.
    int count = procListChildPIDs(
        steamPID, children, (int)sizeof(children));
    if (count <= 0) return 0;
    count = MIN(count, (int)(sizeof(children) / sizeof(children[0])));
    for (int index = 0; index < count; index++) {
        pid_t child = children[index];
        if (child <= 1) continue;
        NSString *path = RootExecutablePathForPID(child);
        if (![path isEqualToString:@(kSteamUIExecutable)]) continue;
        errno = 0;
        if (kill(child, 0) != 0 && errno == ESRCH) continue;
        if (!requireVisibleWindow) return child;
        int exitStatus = -1;
        if (WaitForWindowMetrics(child, 0.11, &exitStatus)) return child;
    }
    return 0;
}

static pid_t WaitForSteamUIProcess(pid_t steamPID, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (deadline.timeIntervalSinceNow > 0) {
        pid_t owner = FindSteamUIProcess(steamPID, YES);
        if (owner > 1) return owner;
        errno = 0;
        if (kill(steamPID, 0) != 0 && errno == ESRCH) return 0;
        usleep(100000);
    }
    return 0;
}

static NSString *ApplicationSessionIdentifierForPath(NSString *rootPath) {
    if (!rootPath.length) return @"app";
    if ([rootPath isEqualToString:@(kVSCodeExecutable)] ||
        [rootPath isEqualToString:@(kVSCodeBundleExecutable)]) return @"vscode";
    if ([rootPath isEqualToString:@(kSteamOuterExecutable)] ||
        [rootPath isEqualToString:@(kSteamLiveExecutable)]) return @"steam";
    if ([rootPath isEqualToString:@(kMapsExecutable)]) return @"maps";
    if ([rootPath isEqualToString:@(kWeatherExecutable)]) return @"weather";
    if ([rootPath isEqualToString:@(kAsphaltExecutable)]) return @"asphalt";
    for (NSUInteger index = 0;
         index < sizeof(kAllowedApps) / sizeof(kAllowedApps[0]); index++) {
        if ([rootPath isEqualToString:@(kAllowedApps[index].rootPath)])
            return @(kAllowedApps[index].identifier);
    }
    return rootPath.lastPathComponent.length
        ? rootPath.lastPathComponent : @"app";
}

static NSString *ApplicationSessionKey(NSString *identifier,
                                       NSString *rootPath) {
    return [NSString stringWithFormat:@"%@|%@", identifier ?: @"app",
                                      rootPath ?: @""];
}

// Track the concrete process that owns one user-visible application session.
// Process identity is always the resolved executable path plus PID; a Dock
// label, p_comm string or a stale LaunchServices record is never accepted as
// proof that the session is reusable.
static void TrackApplicationSession(NSString *identifier,
                                    NSString *rootPath, pid_t pid) {
    if (pid <= 1 || !rootPath.length || !gApplicationSessions) return;
    NSString *resolvedIdentifier = identifier.length
        ? identifier : ApplicationSessionIdentifierForPath(rootPath);
    NSString *key = ApplicationSessionKey(resolvedIdentifier, rootPath);
    NSNumber *oldPID = gApplicationSessions[key][@"pid"];
    gApplicationSessions[key] = [@{
        @"identifier": resolvedIdentifier,
        @"rootPath": rootPath,
        @"pid": @(pid),
    } mutableCopy];
    if (oldPID.intValue != pid) {
        HostLog(@"app-session track id=%@ pid=%d executable=%@ previous=%d",
                resolvedIdentifier, pid, rootPath, oldPID.intValue);
    }
    if ([resolvedIdentifier isEqualToString:@"steam"] ||
        [resolvedIdentifier isEqualToString:@"stray"] ||
        [rootPath isEqualToString:@(kStrayExecutable)]) {
        // A newly tracked owner starts one bounded discovery cycle so the
        // exact overlay/game PIDs can subsequently be followed without a
        // process-table scan on every supervisor tick.
        gNextSteamProcessDiscovery = 0;
    }
}

static void ApplicationSessionObservedExit(pid_t pid, NSString *identifier,
                                           NSString *witness) {
    if (pid <= 1) return;
    BOOL removed = NO;
    NSString *resolvedIdentifier = identifier.length ? identifier : @"app";
    for (NSString *key in [gApplicationSessions.allKeys copy]) {
        NSDictionary *session = gApplicationSessions[key];
        if ([session[@"pid"] intValue] != pid) continue;
        if (!identifier.length)
            resolvedIdentifier = session[@"identifier"] ?: @"app";
        [gApplicationSessions removeObjectForKey:key];
        removed = YES;
    }
    os_unfair_lock_lock(&gStateLock);
    if (gActiveAppPID == pid) {
        gActiveAppPID = 0;
        gActiveAppID = @"";
        removed = YES;
    }
    os_unfair_lock_unlock(&gStateLock);
    if (!removed) return;
    HostLog(@"app-session exit id=%@ pid=%d witness=%@",
            resolvedIdentifier, pid, witness ?: @"process-absent");
}

static BOOL ApplicationSessionPIDMatchesPath(pid_t pid, NSString *rootPath,
                                             NSString *identifier) {
    errno = 0;
    if (kill(pid, 0) != 0 && errno == ESRCH) return NO;
    NSString *actualPath = RootExecutablePathForPID(pid);
    if (!actualPath.length) return errno == EPERM;
    if ([identifier isEqualToString:@"steam"])
        return [actualPath isEqualToString:@(kSteamOuterExecutable)] ||
               [actualPath isEqualToString:@(kSteamLiveExecutable)] ||
               SteamPIDMatchesProductionJob(pid, actualPath);
    return [actualPath isEqualToString:rootPath];
}

static void RetireConfirmedSteamOverlayOrphan(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    pid_t steamPID = 0;
    for (NSDictionary *session in gApplicationSessions.allValues) {
        NSString *identifier = session[@"identifier"] ?: @"";
        NSString *rootPath = session[@"rootPath"] ?: @"";
        if ([identifier isEqualToString:@"steam"]) {
            steamPID = (pid_t)[session[@"pid"] intValue];
            break;
        }
        if ([identifier isEqualToString:@"stray"] ||
            [rootPath isEqualToString:@(kStrayExecutable)])
            gKnownStrayPID = (pid_t)[session[@"pid"] intValue];
    }

    if (gKnownSteamOverlayPID > 1 &&
        !ApplicationSessionPIDMatchesPath(
            gKnownSteamOverlayPID, @(kSteamOverlayExecutable), @"overlay"))
        gKnownSteamOverlayPID = 0;
    if (gKnownStrayPID > 1 &&
        !ApplicationSessionPIDMatchesPath(
            gKnownStrayPID, @(kStrayExecutable), @"stray"))
        gKnownStrayPID = 0;

    BOOL trackedOwnerPresent = steamPID > 1 || gKnownStrayPID > 1;
    BOOL transitionNeedsDiscovery =
        gSteamOwnerWasPresent && !trackedOwnerPresent;
    BOOL discoveryDue = !gSteamProcessDiscoveryPrimed ||
        transitionNeedsDiscovery ||
        (steamPID > 1 && now >= gNextSteamProcessDiscovery);
    if (discoveryDue) {
        // These are the only full process-table walks in this lifecycle.  One
        // runs when hostd starts, one every five seconds while Steam is live,
        // and one when its tracked owner disappears so a still-live Stray is
        // not mistaken for an orphaned overlay owner.
        gKnownSteamOverlayPID =
            FindRunningRootExecutable(@(kSteamOverlayExecutable));
        gKnownStrayPID = FindRunningRootExecutable(@(kStrayExecutable));
        gSteamProcessDiscoveryPrimed = YES;
        gNextSteamProcessDiscovery = now + 5.0;
        trackedOwnerPresent = steamPID > 1 || gKnownStrayPID > 1;
    }
    gSteamOwnerWasPresent = trackedOwnerPresent;

    pid_t overlayPID = gKnownSteamOverlayPID;
    pid_t strayPID = gKnownStrayPID;
    if (overlayPID <= 1 || steamPID > 1 || strayPID > 1) {
        gObservedOrphanOverlayPID = 0;
        gObservedOrphanOverlaySince = 0;
        return;
    }
    if (gObservedOrphanOverlayPID != overlayPID) {
        gObservedOrphanOverlayPID = overlayPID;
        gObservedOrphanOverlaySince = now;
        HostLog(@"app-session orphan-observed id=steam-overlay pid=%d "
                "owners=absent grace=2s", overlayPID);
        return;
    }
    if (now - gObservedOrphanOverlaySince < 2.0) return;

    // Runtime-confirmed on 2026-08-22: overlay PID 11489 survived both Stray
    // PID 11479 and Steam PID 5656, was reparented to launchd, consumed ~44%%
    // CPU and ignored SIGTERM.  Only the exact installed overlay executable
    // reaches this path, and both of its legitimate owners must remain absent
    // for a complete grace interval before the bounded TERM/KILL transaction.
    HostLog(@"app-session orphan-retire id=steam-overlay pid=%d signal=TERM",
            overlayPID);
    if (kill(overlayPID, SIGTERM) != 0 && errno != ESRCH) return;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.4];
    while (deadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(overlayPID, 0) != 0 && errno == ESRCH) break;
        usleep(50000);
    }
    errno = 0;
    if (kill(overlayPID, 0) == 0 || errno != ESRCH) {
        HostLog(@"app-session orphan-retire id=steam-overlay pid=%d "
                "signal=KILL reason=term-timeout", overlayPID);
        (void)kill(overlayPID, SIGKILL);
    }
    gKnownSteamOverlayPID = 0;
    gObservedOrphanOverlayPID = 0;
    gObservedOrphanOverlaySince = 0;
}

static void SeedApplicationSessions(void) {
    // Recover sessions that predate a hostd restart from the authoritative
    // per-process window catalogs.  This is what makes quit convergence a
    // service invariant rather than state remembered only by the launch UI.
    NSString *metricsDirectory = @"/var/mnt/rootfs/private/tmp";
    NSArray<NSString *> *entries =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:metricsDirectory
                                                          error:nil];
    for (NSString *entry in entries) {
        int pid = 0;
        char extra = 0;
        if (sscanf(entry.UTF8String, "macws_window_metrics.%d.bin%c",
                   &pid, &extra) != 1 || pid <= 1) continue;
        NSString *rootPath = RootExecutablePathForPID((pid_t)pid);
        if (![rootPath containsString:@".app/Contents/MacOS/"]) continue;
        if ([rootPath containsString:@"/Dock.app/"] ||
            [rootPath containsString:@"/SystemUIServer.app/"] ||
            [rootPath containsString:@"/ControlCenter.app/"] ||
            [rootPath containsString:@"/NotificationCenter.app/"] ||
            [rootPath containsString:@"/loginwindow.app/"] ||
            [rootPath containsString:@"/CoreLocationAgent.app/"] ||
            [rootPath containsString:@"/UIKitSystem.app/"] ||
            [rootPath containsString:@"/Frameworks/"]) continue;
        TrackApplicationSession(
            ApplicationSessionIdentifierForPath(rootPath), rootPath,
            (pid_t)pid);
    }
    pid_t vscodePID = FindRunningRootExecutable(@(kVSCodeExecutable));
    if (vscodePID > 1)
        TrackApplicationSession(@"vscode", @(kVSCodeExecutable), vscodePID);
    pid_t steamPID = FindRunningSteamExecutable();
    if (steamPID > 1) {
        NSString *steamPath = RootExecutablePathForPID(steamPID);
        TrackApplicationSession(@"steam",
            steamPath.length ? steamPath : @(kSteamLiveExecutable), steamPID);
    }
}

static void StartApplicationSessionSupervisor(void) {
    if (gApplicationSupervisorTimer) return;
    SeedApplicationSessions();
    gApplicationSupervisorTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gControlQueue);
    dispatch_source_set_timer(gApplicationSupervisorTimer,
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC,
        100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gApplicationSupervisorTimer, ^{
        for (NSString *key in [gApplicationSessions.allKeys copy]) {
            NSDictionary *session = gApplicationSessions[key];
            pid_t pid = (pid_t)[session[@"pid"] intValue];
            NSString *identifier = session[@"identifier"] ?: @"app";
            NSString *rootPath = session[@"rootPath"] ?: @"";
            if (ApplicationSessionPIDMatchesPath(
                    pid, rootPath, identifier)) continue;
            ApplicationSessionObservedExit(
                pid, identifier, @"supervisor:path-or-process-absent");
        }
        RetireConfirmedSteamOverlayOrphan();
    });
    dispatch_resume(gApplicationSupervisorTimer);
    HostLog(@"app-session supervisor-ready interval=1s sessions=%lu",
            (unsigned long)gApplicationSessions.count);
}

// An AppKit application can outlive its last NSWindow.  That is the normal
// result after an iPad Scene asks AppInputBridge to performClose:, but such a
// process cannot satisfy a later launch request by merely being "reused".
// Gracefully retire only the exact executable whose metrics sidecar remained
// empty for the complete WaitForWindowMetrics grace period.  This keeps the
// single-instance invariant without treating process uptime as a window.
static BOOL TerminateWindowlessRootExecutable(pid_t pid, NSString *rootPath,
                                              NSString **message) {
    if (pid <= 1 || !rootPath.length) return NO;
    HostLog(@"launch-app windowless-retire pid=%d executable=%@ signal=TERM",
            pid, rootPath);
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) {
        *message = [NSString stringWithFormat:
            @"无窗口实例无法正常退出（PID %d，errno=%d）", pid, errno];
        return NO;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.4];
    while (deadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(pid, 0) != 0 && errno == ESRCH) {
            HostLog(@"launch-app windowless-retired pid=%d executable=%@",
                    pid, rootPath);
            return YES;
        }
        usleep(50000);
    }
    // Runtime-confirmed with Terminal on 2026-07-31 and again on 2026-08-06:
    // after its last NSWindow performed the ordinary close action, SIGTERM
    // leaves the zero-window process alive; waiting three seconds changed no
    // state and directly inflated the next launch. The app has already failed
    // its real metrics + AppKit reopen transaction before this helper runs, so
    // retain a bounded 400-ms cooperative grace and then retire that exact
    // executable. This remains a final lifecycle step, not a process-uptime
    // substitute for window health.
    HostLog(@"launch-app windowless-retire pid=%d executable=%@ signal=KILL "
            "reason=term-timeout", pid, rootPath);
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
        *message = [NSString stringWithFormat:
            @"无窗口实例无法清理（PID %d，errno=%d）", pid, errno];
        return NO;
    }
    deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (deadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(pid, 0) != 0 && errno == ESRCH) {
            HostLog(@"launch-app windowless-retired pid=%d executable=%@ "
                    "after=KILL", pid, rootPath);
            return YES;
        }
        usleep(50000);
    }
    *message = [NSString stringWithFormat:
        @"无窗口实例清理超时（PID %d），未创建重复进程", pid];
    return NO;
}

// A LaunchServices session can discard its mounted Settings extension records
// while leaving the already-running SwiftUI shell alive.  Once that shell has
// cached an empty PPCenter catalog, reopening its NSWindow cannot populate the
// panes: runtime A/B on 2026-08-12 kept the old shell blank after all 48
// records verified, while retiring that exact executable and launching it
// again immediately created real Appearance/Trackpad/Mouse extension
// processes.  Retire only that identified process, with the same bounded
// cooperative grace used for a windowless application.
static BOOL RetireRootExecutableForCatalogRefresh(pid_t pid,
                                                  NSString *rootPath,
                                                  NSString **message) {
    if (pid <= 1 || !rootPath.length) return YES;
    HostLog(@"launch-app catalog-refresh-retire pid=%d executable=%@ "
            "signal=TERM", pid, rootPath);
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) {
        *message = [NSString stringWithFormat:
            @"设置目录已修复，但旧进程无法退出（PID %d，errno=%d）",
            pid, errno];
        return NO;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.4];
    while (deadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(pid, 0) != 0 && errno == ESRCH) return YES;
        usleep(50000);
    }
    HostLog(@"launch-app catalog-refresh-retire pid=%d executable=%@ "
            "signal=KILL reason=term-timeout", pid, rootPath);
    if (kill(pid, SIGKILL) != 0 && errno != ESRCH) {
        *message = [NSString stringWithFormat:
            @"设置目录已修复，但旧进程无法清理（PID %d，errno=%d）",
            pid, errno];
        return NO;
    }
    deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
    while (deadline.timeIntervalSinceNow > 0) {
        errno = 0;
        if (kill(pid, 0) != 0 && errno == ESRCH) return YES;
        usleep(50000);
    }
    *message = [NSString stringWithFormat:
        @"设置目录已修复，但旧进程清理超时（PID %d）", pid];
    return NO;
}

// Validate the records actually visible to the current LaunchServices
// generation immediately before launching System Settings.  The startup
// marker alone is insufficient: runtime-confirmed on 2026-08-12, the same
// session that had prepared 48/48 panes later returned an
// LSApplicationExtensionRecord with identifier=<nil>, platform=0 and url=nil.
// Re-register through stock LaunchServices only when the exact verifier fails;
// do not manufacture a pane or treat process uptime as content readiness.
static BOOL EnsureSystemSettingsCatalog(BOOL *repairedOut,
                                        NSString **message) {
    if (repairedOut) *repairedOut = NO;
    const char *verify[] = {
        kChrootExec, "0", "0", kRootFS, kWorkspaceCtl,
        "verify-launchservices-catalog", NULL,
    };
    int verifyResult = RunCommand(verify, YES);
    if (verifyResult == 0) {
        HostLog(@"system-settings catalog result=verified action=reuse");
        return YES;
    }

    static const char *const registrationEnvironment[] = {
        "MACWS_CATALOG_REGISTRATION=1",
    };
    char **environment = CopyEnvironmentAdding(
        registrationEnvironment,
        sizeof(registrationEnvironment) /
            sizeof(registrationEnvironment[0]));
    if (!environment) {
        *message = @"无法构造系统设置目录修复环境";
        return NO;
    }
    const char *repairCatalog[] = {
        kChrootExec, "0", "0", kRootFS, kWorkspaceCtl,
        "repair-launchservices-catalog", NULL,
    };
    int repairResult = RunCommandWithEnvironment(
        repairCatalog, environment, YES);
    FreeCopiedEnvironment(environment);
    int repairedVerifyResult = repairResult == 0
        ? RunCommand(verify, YES) : 126;
    HostLog(@"system-settings catalog result=%s initial_verify=%d "
            "repair=%d final_verify=%d",
            repairedVerifyResult == 0 ? "repaired" : "failed",
            verifyResult, repairResult, repairedVerifyResult);
    if (repairedVerifyResult != 0) {
        *message = [NSString stringWithFormat:
            @"系统设置目录修复失败（验证 %d，修复 %d，复验 %d）",
            verifyResult, repairResult, repairedVerifyResult];
        return NO;
    }
    if (repairedOut) *repairedOut = YES;
    return YES;
}

static pid_t RunningBoardSettingsBridgePublisherPID(void) {
    uint64_t state = 0;
    return MacWSSettingsBridgeLiveCapabilities(&state)
        ? (pid_t)MacWSSettingsBridgePublisher(state) : 0;
}

// RunningBoard is a stock iOS daemon and can predate Dopamine's injection
// environment after a fresh boot. Runtime LLDB on pid 48077 proved that its
// image list lacked MacWSCatalystLaunch.dylib; the next Settings request then
// reached launchd with the real macOS Appearance path and failed with
// OSLaunchdErrorDomain/148. Restart exactly that daemon only when the tweak's
// live capability does not identify the current process generation, and
// require the new hook-installed capability before submitting a pane request.
static BOOL EnsureRunningBoardSettingsBridge(NSString **message) {
    NSString *runningBoardPath = @"/usr/libexec/runningboardd";
    pid_t currentPID = FindRunningRootExecutable(runningBoardPath);
    pid_t publisherPID = RunningBoardSettingsBridgePublisherPID();
    // notifyd can ask a live publisher to restore its state after a service
    // reconnect. Give that asynchronous reply a bounded chance before the
    // existing cold-boot recovery restarts a pre-jailbreak RunningBoard.
    if (currentPID > 1 && publisherPID != currentPID) {
        for (unsigned attempt = 0; attempt < 4; attempt++) {
            usleep(25000);
            publisherPID = RunningBoardSettingsBridgePublisherPID();
            if (publisherPID == currentPID) break;
        }
    }
    if (currentPID > 1 && publisherPID == currentPID) {
        HostLog(@"system-settings runningboard-bridge result=verified pid=%d",
                currentPID);
        return YES;
    }

    HostLog(@"system-settings runningboard-bridge action=restart "
            "current-pid=%d publisher-pid=%d", currentPID, publisherPID);
    const char *restart[] = {
        kLaunchctl, "kickstart", "-k",
        "user/foreground/com.apple.runningboardd", NULL,
    };
    int restartResult = RunCommand(restart, YES);
    if (restartResult != 0) {
        *message = [NSString stringWithFormat:
            @"系统设置启动桥接器重启失败（状态 %d）", restartResult];
        return NO;
    }

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:6.0];
    pid_t replacementPID = 0;
    do {
        replacementPID = FindRunningRootExecutable(runningBoardPath);
        publisherPID = RunningBoardSettingsBridgePublisherPID();
        if (replacementPID > 1 && replacementPID != currentPID &&
            publisherPID == replacementPID) {
            HostLog(@"system-settings runningboard-bridge result=recovered "
                    "old-pid=%d new-pid=%d", currentPID, replacementPID);
            return YES;
        }
        usleep(100000);
    } while (deadline.timeIntervalSinceNow > 0);

    HostLog(@"system-settings runningboard-bridge result=failed old-pid=%d "
            "replacement-pid=%d publisher-pid=%d", currentPID, replacementPID,
            publisherPID);
    *message = @"系统设置启动桥接器未进入就绪状态";
    return NO;
}

// The desktop needs the shared ViewBridge/ExtensionKit service contracts, but
// it does not execute any of System Settings' 48 pane binaries.  Reconcile
// those per-pane carriers at the actual application boundary so a libmachook
// deployment cannot hold WindowServer startup behind minutes of unrelated
// signing and trustcache work.  This remains fail-closed: System Settings is
// launched only after the unchanged complete verifier succeeds.
static BOOL EnsureSystemSettingsExtensionRuntime(NSString **message) {
    SetState(YES, @"正在验证系统设置扩展运行时…", @"");
    (void)unlink(kSettingsExtensionsRuntimeLog);
    const char *verify[] = {
        kBash, kSettingsExtensionsRuntime, "--verify", NULL,
    };
    int initialVerify = RunCommandToLog(
        verify, YES, kSettingsExtensionsRuntimeLog);
    if (initialVerify == 0) {
        HostLog(@"system-settings runtime result=verified action=reuse");
        return YES;
    }

    SetState(YES, @"正在增量更新系统设置依赖…", @"");
    const char *repairDependencies[] = {
        kBash, kSettingsExtensionsRuntime, "--repair-dependencies", NULL,
    };
    int dependencyRepair = RunCommandToLog(
        repairDependencies, YES, kSettingsExtensionsRuntimeLog);
    int dependencyVerify = dependencyRepair == 0
        ? RunCommandToLog(verify, YES, kSettingsExtensionsRuntimeLog) : 126;
    if (dependencyVerify == 0) {
        HostLog(@"system-settings runtime result=verified "
                "action=dependency-reconcile initial_verify=%d repair=%d",
                initialVerify, dependencyRepair);
        return YES;
    }

    SetState(YES, @"正在完整修复系统设置扩展…", @"");
    const char *prepare[] = {
        kBash, kSettingsExtensionsRuntime, NULL,
    };
    int prepareResult = RunCommandToLog(
        prepare, YES, kSettingsExtensionsRuntimeLog);
    int finalVerify = prepareResult == 0
        ? RunCommandToLog(verify, YES, kSettingsExtensionsRuntimeLog) : 126;
    HostLog(@"system-settings runtime result=%s initial_verify=%d "
            "dependency_repair=%d dependency_verify=%d prepare=%d "
            "final_verify=%d",
            finalVerify == 0 ? "prepared" : "failed",
            initialVerify, dependencyRepair, dependencyVerify,
            prepareResult, finalVerify);
    if (finalVerify != 0) {
        *message = [NSString stringWithFormat:
            @"系统设置扩展运行时准备失败（验证 %d，准备 %d，复验 %d）",
            initialVerify, prepareResult, finalVerify];
        return NO;
    }
    return YES;
}

static pid_t WaitForRunningRootExecutable(NSString *rootPath,
                                          NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    do {
        pid_t pid = FindRunningRootExecutable(rootPath);
        if (pid > 1) return pid;
        usleep(100000);
    } while (deadline.timeIntervalSinceNow > 0);
    return 0;
}

static BOOL MapsHostCarrierMarkerMatches(pid_t pid) {
    char value[32] = {0};
    int fd = open(kMapsHostCarrierMarker, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    ssize_t count = read(fd, value, sizeof(value) - 1);
    close(fd);
    int markerPID = 0;
    return count > 0 && sscanf(value, "%d", &markerPID) == 1 &&
        markerPID == pid && pid > 1;
}

static BOOL CatalystChildMarkerMatches(pid_t pid, const char *rootExecutable,
                                       const char *bundleIdentifier) {
    if (pid <= 1 || !rootExecutable || !bundleIdentifier) return NO;
    char markerPath[PATH_MAX] = {0};
    int length = snprintf(
        markerPath, sizeof(markerPath),
        "/var/mnt/rootfs/private/tmp/macws_catalyst_child.%d.info", pid);
    if (length <= 0 || (size_t)length >= sizeof(markerPath)) return NO;
    int fd = open(markerPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat status = {0};
    char payload[PATH_MAX + 512] = {0};
    ssize_t count = read(fd, payload, sizeof(payload) - 1);
    int statusResult = fstat(fd, &status);
    close(fd);
    if (count <= 0 || (size_t)count >= sizeof(payload) ||
        statusResult != 0 || !S_ISREG(status.st_mode) ||
        status.st_uid != 0 || (status.st_mode & 022) != 0 ||
        status.st_nlink != 1) return NO;
    payload[count] = '\0';
    NSString *expected = [NSString stringWithFormat:@"v1\n%s\n%s\n",
                          rootExecutable, bundleIdentifier];
    return strcmp(payload, expected.UTF8String) == 0;
}

static BOOL WriteCatalystLaunchRequest(const char *rootExecutable,
                                       const char *bundleIdentifier,
                                       const char *containerHome,
                                       NSString **message) {
    NSDictionary *request = @{
        @"root_executable": @(rootExecutable),
        @"bundle_identifier": @(bundleIdentifier),
        @"container_home": @(containerHome),
    };
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:request
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:&serializationError];
    if (!data) {
        *message = [NSString stringWithFormat:
            @"无法构造 Catalyst 启动请求：%@",
            serializationError.localizedDescription ?: @"未知错误"];
        return NO;
    }
    char temporaryPath[PATH_MAX] = {0};
    int length = snprintf(temporaryPath, sizeof(temporaryPath),
                          "%s.new.%d", kCatalystRequestPath, getpid());
    if (length <= 0 || (size_t)length >= sizeof(temporaryPath)) {
        *message = @"Catalyst 启动请求路径过长";
        return NO;
    }
    unlink(temporaryPath);
    int fd = open(temporaryPath,
                  O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                  0600);
    if (fd < 0) {
        *message = [NSString stringWithFormat:
            @"无法创建 Catalyst 启动请求（errno=%d）", errno];
        return NO;
    }
    const uint8_t *cursor = data.bytes;
    size_t remaining = data.length;
    BOOL written = YES;
    while (remaining > 0) {
        ssize_t count = write(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            written = NO;
            break;
        }
        cursor += count;
        remaining -= (size_t)count;
    }
    if (written && fsync(fd) != 0) written = NO;
    if (close(fd) != 0) written = NO;
    if (!written || rename(temporaryPath, kCatalystRequestPath) != 0) {
        int savedError = errno;
        unlink(temporaryPath);
        *message = [NSString stringWithFormat:
            @"无法发布 Catalyst 启动请求（errno=%d）", savedError];
        return NO;
    }
    return YES;
}

static void RetireLegacyMapsUIKitCarrier(void) {
    // The pre-fullscreen architecture foregrounded this UIApplication and
    // kept its empty UIWindowScene alive after Maps exited.  A process whose
    // executable is still MacWSCatalystLauncher is necessarily that legacy
    // UI carrier: the new helper replaces itself with launchdchrootexec before
    // Maps starts.  Retire it before notifying the foreground Host so the
    // user cannot inherit the old black iPadOS window after an upgrade.
    const char *retire[] = {
        kKillall, "-TERM", "MacWSCatalystLauncher", NULL,
    };
    int result = RunCommand(retire, YES);
    HostLog(@"maps legacy-ui-carrier retire result=%d", result);
}

// Maps is a Mac Catalyst application. MacWSHost is already the foreground
// UIApplication and owns the user's fullscreen scene. Ask that existing Host
// to spawn a setuid helper which immediately execs Maps as its direct child.
// This preserves the valid UIKit/FrontBoard responsible-process ancestry
// without ever foregrounding the old empty MacWSCatalystLauncher UIWindowScene.
static BOOL LaunchMapsViaUIKitCarrier(NSString **message) {
    NSString *mapsRootPath = @(kMapsExecutable);
    NSString *mapsHostPath = [@("/var/mnt/rootfs")
        stringByAppendingString:mapsRootPath];
    if (access(mapsHostPath.fileSystemRepresentation, X_OK) != 0 ||
        access(kUIKitSystemPlist, R_OK) != 0) {
        *message = @"Maps 的 Catalyst 启动组件不完整，请先修复环境";
        return NO;
    }
    if (!JobHasPID(kWindowServerLabel, NULL) ||
        !JobHasPID(kDisplayLabel, NULL)) {
        *message = @"请先启动 macOS GUI 与 DisplayStream";
        return NO;
    }

    RetireLegacyMapsUIKitCarrier();

    pid_t uikitSystemPID = FindRunningRootExecutable(
        @(kUIKitSystemExecutable));
    if (uikitSystemPID <= 1) {
        const char *loadUIKitSystem[] = {
            kLaunchctl, "load", kUIKitSystemPlist, NULL,
        };
        const char *kickstartUIKitSystem[] = {
            kLaunchctl, "kickstart", "-k",
            "user/501/com.apple.uikitsystemapp", NULL,
        };
        (void)RunCommand(loadUIKitSystem, YES);
        (void)RunCommand(kickstartUIKitSystem, YES);
        uikitSystemPID = WaitForRunningRootExecutable(
            @(kUIKitSystemExecutable), 8.0);
        if (uikitSystemPID <= 1) {
            *message = @"UIKitSystem 未能完成 Catalyst 场景服务启动";
            return NO;
        }
    }

    pid_t mapsPID = FindRunningRootExecutable(mapsRootPath);
    BOOL freshHostChild = MapsHostCarrierMarkerMatches(mapsPID);
    if (mapsPID > 1 && !freshHostChild) {
        // A previously published Catalyst scene may be reopened in place.
        // If it is a stale windowless generation, retire it before asking the
        // live Host for one new exact process generation.
        if (RequestApplicationReopen(mapsPID, 8.0)) {
            os_unfair_lock_lock(&gStateLock);
            gActiveAppPID = mapsPID;
            gActiveAppID = @"maps";
            os_unfair_lock_unlock(&gStateLock);
            TrackApplicationSession(@"maps", mapsRootPath, mapsPID);
            HostLog(@"launch-app reuse id=maps pid=%d route=existing-window",
                    mapsPID);
            *message = @"地图已在运行，现有原生窗口已进入窗口列表";
            return YES;
        }
        if (!TerminateWindowlessRootExecutable(
                mapsPID, mapsRootPath, message)) return NO;
        mapsPID = 0;
    }
    if (mapsPID <= 1) {
        unlink(kMapsHostCarrierMarker);
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            kMapsHostLaunchNotification, NULL, NULL, true);
        // The Host-owned setuid carrier intentionally waits up to 30 seconds
        // for macwsinteropd's real location-provider readiness marker before
        // it execs Maps.  A three-second parent timeout reported failure and
        // the frontend retry then called RetireLegacyMapsUIKitCarrier(),
        // SIGTERM'ing the still-correct helper every ~5 seconds.  Runtime
        // witness 2026-08-21: helpers 77970 and 77991 were killed this way;
        // generation 78017 succeeded only after the provider became ready.
        // Give that upstream protocol its declared 30 seconds plus a bounded
        // five-second exec/process-publication allowance.
        mapsPID = WaitForRunningRootExecutable(mapsRootPath, 35.0);
        freshHostChild = MapsHostCarrierMarkerMatches(mapsPID);
    }
    if (mapsPID <= 1) {
        *message = @"MacWSHost 未能从当前工作区启动地图；没有创建黑色 UIKit 载体窗口";
        return NO;
    }
    if (!freshHostChild) {
        *message = @"地图进程没有匹配当前 MacWSHost 的启动代次，已拒绝创建额外 iOS 场景";
        return NO;
    }
    // Do not synchronously wait up to 30 seconds for a Catalyst window here.
    // The foreground Host already owns the DisplayStream catalog and can
    // observe the exact (PID, window ID) publication without polling.  Return
    // the responsible process immediately so its generic pending-window
    // transaction can stabilize and activate that native window while input
    // and the control center remain responsive.
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = mapsPID;
    gActiveAppID = @"maps";
    os_unfair_lock_unlock(&gStateLock);
    TrackApplicationSession(@"maps", mapsRootPath, mapsPID);
    HostLog(@"launch-app process-ready id=maps pid=%d uikitsystem=%d "
            "route=existing-MacWSHost catalog=asynchronous", mapsPID,
            uikitSystemPID);
    *message = @"地图正在当前工作区打开，未创建新的 iPadOS 窗口";
    return YES;
}

// Asphalt is the first third-party Catalyst control-center target. Its
// executable, bundle identity and container are an exact allowlist entry;
// macwshostd publishes one root-owned request and the already-foreground
// MacWSHost creates the responsible-process child. The container is owned by
// the iPadOS login uid (501), matching a normal Catalyst application and its
// Data Protection Keychain session. This is the same upstream
// UIKit/FrontBoard ancestry that runtime-confirmed the native AGX drawable,
// not a bare chroot spawn or a second black UIKit scene.
static BOOL LaunchCatalystViaUIKitCarrier(const char *identifier,
                                          const char *displayName,
                                          const char *executable,
                                          const char *bundleIdentifier,
                                          const char *containerHome,
                                          NSString **message) {
    NSString *rootPath = @(executable);
    NSString *hostPath = [@(kRootFS) stringByAppendingString:rootPath];
    NSString *hostContainer = [@(kRootFS) stringByAppendingString:@(containerHome)];
    NSString *name = @(displayName);
    if (!EnsureCatalystContainer(containerHome, message)) return NO;
    struct stat containerStatus = {0};
    if (!HasExecutableFileMode(hostPath.fileSystemRepresentation) ||
        stat(hostContainer.fileSystemRepresentation, &containerStatus) != 0 ||
        !S_ISDIR(containerStatus.st_mode) ||
        access(kUIKitSystemPlist, R_OK) != 0) {
        *message = [NSString stringWithFormat:
            @"%@ 的可执行文件、容器或 Catalyst 服务不完整", name];
        return NO;
    }
    if (!JobHasPID(kWindowServerLabel, NULL) ||
        !JobHasPID(kDisplayLabel, NULL)) {
        *message = @"请先启动 macOS GUI 与 DisplayStream";
        return NO;
    }

    pid_t uikitSystemPID = FindRunningRootExecutable(
        @(kUIKitSystemExecutable));
    if (uikitSystemPID <= 1) {
        const char *loadUIKitSystem[] = {
            kLaunchctl, "load", kUIKitSystemPlist, NULL,
        };
        const char *kickstartUIKitSystem[] = {
            kLaunchctl, "kickstart", "-k",
            "user/501/com.apple.uikitsystemapp", NULL,
        };
        (void)RunCommand(loadUIKitSystem, YES);
        (void)RunCommand(kickstartUIKitSystem, YES);
        uikitSystemPID = WaitForRunningRootExecutable(
            @(kUIKitSystemExecutable), 8.0);
        if (uikitSystemPID <= 1) {
            *message = [NSString stringWithFormat:
                @"UIKitSystem 未能完成 %@ 场景服务启动", name];
            return NO;
        }
    }

    pid_t catalystPID = FindRunningRootExecutable(rootPath);
    if (catalystPID > 1) {
        BOOL exactCarrier = CatalystChildMarkerMatches(
            catalystPID, executable, bundleIdentifier);
        if (exactCarrier && RequestApplicationReopen(catalystPID, 8.0)) {
            os_unfair_lock_lock(&gStateLock);
            gActiveAppPID = catalystPID;
            gActiveAppID = @(identifier);
            os_unfair_lock_unlock(&gStateLock);
            TrackApplicationSession(@(identifier), rootPath, catalystPID);
            *message = [NSString stringWithFormat:
                @"%@ 已在当前 macPad 工作区运行", name];
            return YES;
        }
        if (!TerminateWindowlessRootExecutable(catalystPID, rootPath, message))
            return NO;
    }

    if (strcmp(identifier, "weather") == 0 &&
        !RotateWeatherKnownSceneSessions(message)) return NO;

    RetireLegacyMapsUIKitCarrier();
    if (!WriteCatalystLaunchRequest(
            executable, bundleIdentifier, containerHome, message)) return NO;
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kCatalystHostLaunchNotification, NULL, NULL, true);
    catalystPID = WaitForRunningRootExecutable(rootPath, 5.0);
    unlink(kCatalystRequestPath);
    if (catalystPID <= 1) {
        *message = [NSString stringWithFormat:
            @"macPad 未能在当前工作区启动 %@", name];
        return NO;
    }
    if (!CatalystChildMarkerMatches(
            catalystPID, executable, bundleIdentifier)) {
        NSString *retireMessage = nil;
        (void)TerminateWindowlessRootExecutable(
            catalystPID, rootPath, &retireMessage);
        *message = [NSString stringWithFormat:
            @"%@ 进程缺少匹配的 Host Catalyst 身份，已拒绝", name];
        return NO;
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = catalystPID;
    gActiveAppID = @(identifier);
    os_unfair_lock_unlock(&gStateLock);
    TrackApplicationSession(@(identifier), rootPath, catalystPID);
    HostLog(@"launch-app process-ready id=%s pid=%d uikitsystem=%d "
            "route=existing-MacWSHost catalog=asynchronous",
            identifier, catalystPID, uikitSystemPID);
    *message = [NSString stringWithFormat:
        @"%@ 正在当前工作区打开，未创建新的 iPadOS 窗口", name];
    return YES;
}

static BOOL LaunchAsphaltViaUIKitCarrier(NSString **message) {
    return LaunchCatalystViaUIKitCarrier(
        "asphalt", "Asphalt", kAsphaltExecutable,
        kAsphaltBundleIdentifier, kAsphaltContainerHome, message);
}

static BOOL LaunchWeatherViaUIKitCarrier(NSString **message) {
    return LaunchCatalystViaUIKitCarrier(
        "weather", "天气", kWeatherExecutable,
        kWeatherBundleIdentifier, kWeatherContainerHome, message);
}

static BOOL EnsureVSCodeAudioBridge(NSString **message) {
    const char *labels[] = {
        kAudioComponentRegistrarLabel, kCoreAudioLabel, kAudioOutputLabel,
    };
    const char *plists[] = {
        kAudioComponentRegistrarPlist, kCoreAudioPlist, kAudioOutputPlist,
    };
    for (NSUInteger index = 0;
         index < sizeof(labels) / sizeof(labels[0]); index++) {
        BOOL loaded = NO;
        int pid = 0;
        (void)InspectJob(labels[index], &pid, &loaded);
        if (!loaded) {
            if (access(plists[index], R_OK) != 0) {
                if (message) *message = [NSString stringWithFormat:
                    @"VS Code 音频服务配置缺失：%s", plists[index]];
                return NO;
            }
            const char *loadArgv[] = {
                kLaunchctl, "load", plists[index], NULL,
            };
            int result = RunCommand(loadArgv, YES);
            (void)InspectJob(labels[index], &pid, &loaded);
            HostLog(@"vscode-audio self-heal label=%s load=%d loaded=%@ pid=%d",
                    labels[index], result, loaded ? @"YES" : @"NO", pid);
            if (result != 0 || !loaded) {
                if (message) *message = [NSString stringWithFormat:
                    @"VS Code 音频服务未能注册：%s", labels[index]];
                return NO;
            }
        }
        if (strcmp(labels[index], kAudioOutputLabel) == 0 && pid <= 1) {
            // KeepAlive normally starts this job immediately.  If launchd has
            // retained a loaded-but-dormant definition, explicitly requesting
            // the same registered job is cheaper and safer than cycling the
            // rest of the audio graph.
            const char *startArgv[] = {
                kLaunchctl, "start", labels[index], NULL,
            };
            (void)RunCommand(startArgv, YES);
            if (!WaitForJobPID(labels[index], 3.0, &pid)) {
                if (message)
                    *message = @"VS Code 音频输出服务已注册但未运行";
                return NO;
            }
        }
    }
    return YES;
}

static BOOL LaunchVSCode(NSString **message) {
    if (access(kVSCodePlist, R_OK) != 0 ||
        access("/var/mnt/rootfs/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
               X_OK) != 0) {
        *message = @"VS Code 或生产启动配置不存在";
        return NO;
    }
    // cleanup_all intentionally unloads project-owned jobs during emergency
    // recovery. A later window-only recovery can leave the long-lived
    // coreaudiod/registrar alive while macwsaudiooutd remains absent; runtime
    // evidence on 2026-09-16 showed exactly that split state and a silent
    // YouTube renderer. Repair the complete three-job contract before both a
    // fresh VS Code launch and reuse of an existing Electron generation.
    if (!EnsureVSCodeAudioBridge(message)) return NO;
    int pid = 0;
    off_t launchLogOffset = FileSizeAtPath(kVSCodeLog);
    BOOL jobLoaded = NO;
    BOOL reusedJob = InspectJob(kVSCodeLabel, &pid, &jobLoaded);
    if (!reusedJob) {
        // A one-shot launchd job can remain loaded with no PID after Electron
        // exits. Treat that state separately from a genuinely absent job: the
        // former needs `start`, while the latter needs `load` immediately.
        const char *startArgv[] = {kLaunchctl, "start", kVSCodeLabel, NULL};
        const char *loadArgv[] = {kLaunchctl, "load", kVSCodePlist, NULL};
        int loadResult = 0;
        if (jobLoaded) {
            (void)RunCommand(startArgv, YES);
            (void)WaitForJobPID(kVSCodeLabel, 2.0, &pid);
        } else {
            // Runtime-confirmed on 2026-08-02: after an ordinary unload the
            // former start-first path waited its entire two-second dormant-job
            // grace even though `launchctl list` had already established that
            // the label did not exist. Load an absent job immediately; retain
            // start-first only for the distinct loaded-without-PID state.
            loadResult = RunCommand(loadArgv, YES);
            (void)WaitForJobPID(kVSCodeLabel, 3.0, &pid);
        }
        if (pid <= 1) {
            if (jobLoaded)
                loadResult = RunCommand(loadArgv, YES);
            if (!WaitForJobPID(kVSCodeLabel, 3.0, &pid)) {
                // A loaded-but-damaged definition did not respond to start and
                // also rejected load. Refresh that exact production plist;
                // never use a bare Electron spawn with a different environment.
                HostLog(@"launch-app vscode-refresh-job start/load result=%d",
                        loadResult);
                const char *unloadArgv[] = {
                    kLaunchctl, "unload", kVSCodePlist, NULL};
                (void)RunCommand(unloadArgv, YES);
                launchLogOffset = FileSizeAtPath(kVSCodeLog);
                if (RunCommand(loadArgv, YES) != 0)
                    pid = 0;
                else
                    (void)WaitForJobPID(kVSCodeLabel, 10.0, &pid);
            }
        }
    }
    if (pid <= 1) {
        *message = @"VS Code 生产任务未取得进程";
        return NO;
    }
    if (!reusedJob) WriteVSCodeHealthMarker(pid, launchLogOffset);
    if (reusedJob) {
        int reuseExitStatus = -1;
        uint32_t workspaceFlags = MacWSStreamWindowVisible |
                                  MacWSStreamWindowResizable;
        pid_t markerPID = 0;
        off_t markerOffset = 0;
        BOOL markerMatches = ReadVSCodeHealthMarker(&markerPID, &markerOffset) &&
                             markerPID == pid;
        BOOL electronUnresponsive = markerMatches &&
            VSCodeLogContainsUnresponsiveAfter(markerOffset);
        BOOL metalCommandFailure = markerMatches &&
            VSCodeLogContainsCommandBufferFailureAfter(markerOffset);
        BOOL workspaceReady = WaitForWindowMetricsFlags(
            pid, 3.0, workspaceFlags, &reuseExitStatus);
        if (!markerMatches)
            WriteVSCodeHealthMarker(pid, FileSizeAtPath(kVSCodeLog));
        if (!workspaceReady || electronUnresponsive || metalCommandFailure) {
            // Runtime-confirmed on 2026-07-31: Electron logged
            // `CodeWindow: detected unresponsive`; its metrics sidecar then
            // continued to describe a visible/resizable base NSWindow under
            // the recovery sheet. Window geometry therefore cannot establish
            // renderer health. Use Electron's exact per-launch health witness;
            // the production launchd job remains the restart boundary.
            HostLog(@"launch-app vscode-restart pid=%d "
                    "reason=%@", pid,
                    electronUnresponsive ? @"electron-unresponsive" :
                    (metalCommandFailure ? @"metal-command-buffer-failure" :
                                           @"no-resizable-workspace"));
            const char *unloadArgv[] = {kLaunchctl, "unload", kVSCodePlist, NULL};
            (void)RunCommand(unloadArgv, YES);
            launchLogOffset = FileSizeAtPath(kVSCodeLog);
            const char *loadArgv[] = {kLaunchctl, "load", kVSCodePlist, NULL};
            if (RunCommand(loadArgv, YES) != 0) {
                *message = @"VS Code 无响应实例已停止，但生产任务重启失败";
                return NO;
            }
            pid = 0;
            (void)WaitForJobPID(kVSCodeLabel, 15.0, &pid);
            if (pid <= 1) {
                *message = @"VS Code 生产任务重启后未取得进程";
                return NO;
            }
            WriteVSCodeHealthMarker(pid, launchLogOffset);
        }
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = pid;
    gActiveAppID = @"vscode";
    os_unfair_lock_unlock(&gStateLock);
    TrackApplicationSession(@"vscode", @(kVSCodeExecutable), pid);
    int exitStatus = -1;
    if (!WaitForWindowMetricsFlags(pid, 30.0,
            MacWSStreamWindowVisible | MacWSStreamWindowResizable,
            &exitStatus)) {
        *message = @"VS Code 正在运行，但 30 秒内没有发布可调尺寸的工作区窗口";
        return NO;
    }
    // A black Electron client still owns a perfectly real, visible NSWindow.
    // Runtime-confirmed on VS Code PID 27637 / GPU helper 27643 on
    // 2026-08-22: the raw WindowServer capture and macPad capture were both
    // black while this exact Metal completion error repeated in vscode.log.
    // Treat renderer completion as part of content readiness; geometry alone
    // must never turn that failure into a successful launch result.
    usleep(500000);
    pid_t healthPID = 0;
    off_t healthOffset = 0;
    if (ReadVSCodeHealthMarker(&healthPID, &healthOffset) &&
        healthPID == pid &&
        VSCodeLogContainsCommandBufferFailureAfter(healthOffset)) {
        HostLog(@"launch-app content-failed id=vscode pid=%d "
                "reason=metal-command-buffer-failure", pid);
        *message = @"VS Code 窗口已出现，但渲染命令失败，未把黑色窗口视为可用";
        return NO;
    }
    HostLog(@"launch-app window-ready id=vscode pid=%d path=DisplayStream", pid);
    *message = @"VS Code 已通过生产 AGX/JIT 配置启动，窗口已进入列表";
    return YES;
}

static NSString *ValidatedWebURL(xpc_object_t request, NSString **message) {
    const char *requested = xpc_dictionary_get_string(
        request, MACWS_CONTROL_KEY_WEB_URL);
    size_t length = requested
        ? strnlen(requested, MACWS_VSCODE_URL_MAX_BYTES + 1) : 0;
    if (length == 0 || length > MACWS_VSCODE_URL_MAX_BYTES) {
        if (message) *message = @"网页链接为空或过长";
        return nil;
    }
    NSString *value = [[NSString alloc] initWithBytes:requested
                                               length:length
                                             encoding:NSUTF8StringEncoding];
    NSURLComponents *components = value
        ? [NSURLComponents componentsWithString:value] : nil;
    NSString *scheme = components.scheme.lowercaseString;
    BOOL valid = components &&
        ([scheme isEqualToString:@"http"] ||
         [scheme isEqualToString:@"https"]) &&
        components.host.length != 0 &&
        components.user.length == 0 && components.password.length == 0 &&
        components.URL.absoluteString.length != 0;
    if (!valid) {
        if (message) *message = @"只接受不含用户凭据的完整 HTTP/HTTPS 链接";
        return nil;
    }
    NSData *encoded = [components.URL.absoluteString
        dataUsingEncoding:NSUTF8StringEncoding];
    if (encoded.length == 0 || encoded.length > MACWS_VSCODE_URL_MAX_BYTES) {
        if (message) *message = @"规范化后的网页链接过长";
        return nil;
    }
    return components.URL.absoluteString;
}

static BOOL SendAllSocketBytes(int descriptor, const void *buffer,
                               size_t length, int *errorOut) {
    const uint8_t *bytes = buffer;
    size_t offset = 0;
    while (offset < length) {
        ssize_t amount = send(descriptor, bytes + offset, length - offset, 0);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) {
            if (errorOut) *errorOut = amount < 0 ? errno : EPIPE;
            return NO;
        }
        offset += (size_t)amount;
    }
    return YES;
}

static BOOL SendWebURLToVSCodeExtension(NSString *url,
                                        NSTimeInterval timeout,
                                        int *errorOut) {
    NSData *payload = [url dataUsingEncoding:NSUTF8StringEncoding];
    if (payload.length == 0 || payload.length > MACWS_VSCODE_URL_MAX_BYTES) {
        if (errorOut) *errorOut = EINVAL;
        return NO;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    int descriptor = -1;
    int savedError = ENOENT;
    while (deadline.timeIntervalSinceNow > 0) {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
        if (descriptor < 0) {
            savedError = errno;
            break;
        }
        struct timeval socketTimeout = {.tv_sec = 10, .tv_usec = 0};
        (void)setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO,
                         &socketTimeout, sizeof(socketTimeout));
        (void)setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO,
                         &socketTimeout, sizeof(socketTimeout));
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, kVSCodeURLSocket,
                sizeof(address.sun_path));
        if (connect(descriptor, (const struct sockaddr *)&address,
                    sizeof(address)) == 0) break;
        savedError = errno;
        close(descriptor);
        descriptor = -1;
        usleep(50000);
    }
    if (descriptor < 0) {
        if (errorOut) *errorOut = savedError;
        return NO;
    }
    uint32_t networkLength = htonl((uint32_t)payload.length);
    BOOL transferred = SendAllSocketBytes(
        descriptor, &networkLength, sizeof(networkLength), &savedError) &&
        SendAllSocketBytes(descriptor, payload.bytes, payload.length,
                           &savedError);
    // The request is length-framed, so EOF is not part of its boundary.
    // Do not half-close here: Node net.Server defaults allowHalfOpen to false
    // and would mirror our FIN before the asynchronous simpleBrowser.show
    // command can write its one-byte completion acknowledgement.
    uint8_t acknowledgement = 0;
    ssize_t received = transferred
        ? recv(descriptor, &acknowledgement, sizeof(acknowledgement), 0) : -1;
    if (received < 0) savedError = errno;
    else if (received != 1 || acknowledgement != 1) savedError = EPROTO;
    close(descriptor);
    BOOL accepted = transferred && received == 1 && acknowledgement == 1;
    if (errorOut) *errorOut = accepted ? 0 : savedError;
    return accepted;
}

static void ActivateVSCodeAfterWebOpen(pid_t pid) {
    if (pid <= 1 || !WaitForAppInputEndpoint(pid, 1.0)) return;
    static _Atomic uint32_t sequence = 0;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindActivateTarget,
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = pid,
        .source = MacWSInputSourceUnknown,
        .sampleSequence = atomic_fetch_add(&sequence, 1) + 1,
    };
    int sendError = 0;
    BOOL sent = SendAppInputRecord(pid, &record, &sendError);
    HostLog(@"open-web-url activate pid=%d sent=%@ errno=%d", pid,
            sent ? @"YES" : @"NO", sendError);
}

static BOOL OpenWebURLRequest(xpc_object_t request, pid_t *targetPIDOut,
                              NSString **message) {
    NSString *url = ValidatedWebURL(request, message);
    if (!url) return NO;
    if (!LaunchVSCode(message)) return NO;
    os_unfair_lock_lock(&gStateLock);
    pid_t targetPID = gActiveAppPID;
    os_unfair_lock_unlock(&gStateLock);
    if (targetPID <= 1) {
        if (message) *message = @"VS Code 已启动，但没有有效进程";
        return NO;
    }
    int sendError = 0;
    BOOL accepted = SendWebURLToVSCodeExtension(url, 12.0, &sendError);
    NSURLComponents *components = [NSURLComponents componentsWithString:url];
    HostLog(@"open-web-url target=vscode pid=%d result=%@ errno=%d "
            "scheme=%@ host=%@",
            targetPID, accepted ? @"simple-browser-accepted" : @"failed",
            sendError, components.scheme ?: @"", components.host ?: @"");
    if (!accepted) {
        if (message) *message = [NSString stringWithFormat:
            @"VS Code Simple Browser 没有确认链接（errno=%d）", sendError];
        return NO;
    }
    ActivateVSCodeAfterWebOpen(targetPID);
    if (targetPIDOut) *targetPIDOut = targetPID;
    if (message) *message = @"链接已由 VS Code Simple Browser 接收";
    return YES;
}

static BOOL SteamPIDMatchesProductionJob(pid_t pid, NSString *actualPath) {
    if (pid <= 1) return NO;
    int jobPID = 0;
    if (!JobHasPID(kSteamLabel, &jobPID) || jobPID != pid) return NO;
    NSString *path = actualPath.length
        ? actualPath : RootExecutablePathForPID(pid);
    // Runtime-confirmed on 2026-08-22 for the production Steam job PID 12654:
    // proc_pidpath returned the argv-relative spelling `./steam_osx`, even
    // though launchd had already exec'd the exact Steam job and its visible
    // AppKit/CEF window was live. Bind that spelling only to the PID currently
    // owned by the exact launchd label; the preflight shell is rejected by its
    // different basename until exec completes.
    return [path isEqualToString:@(kSteamOuterExecutable)] ||
           [path isEqualToString:@(kSteamLiveExecutable)] ||
           [path.lastPathComponent isEqualToString:@"steam_osx"];
}

static pid_t FindRunningSteamExecutable(void) {
    pid_t pid = FindRunningRootExecutable(@(kSteamLiveExecutable));
    if (pid > 1) return pid;
    pid = FindRunningRootExecutable(@(kSteamOuterExecutable));
    if (pid > 1) return pid;
    int jobPID = 0;
    if (JobHasPID(kSteamLabel, &jobPID) &&
        SteamPIDMatchesProductionJob((pid_t)jobPID,
                                     RootExecutablePathForPID(jobPID))) {
        static pid_t loggedJobPID = 0;
        if (loggedJobPID != (pid_t)jobPID) {
            loggedJobPID = (pid_t)jobPID;
            HostLog(@"launch-app steam-identity pid=%d "
                    "source=launchd-job proc-path=%@", jobPID,
                    RootExecutablePathForPID(jobPID) ?: @"(unavailable)");
        }
        return (pid_t)jobPID;
    }
    return 0;
}

static BOOL LaunchSteam(NSString **message) {
    NSString *outerHostPath = [@(kRootFS)
        stringByAppendingString:@(kSteamOuterExecutable)];
    NSString *liveHostPath = [@(kRootFS)
        stringByAppendingString:@(kSteamLiveExecutable)];
    if (access(kSteamPlist, R_OK) != 0 ||
        (!HasExecutableFileMode(outerHostPath.fileSystemRepresentation) &&
         !HasExecutableFileMode(liveHostPath.fileSystemRepresentation))) {
        *message = @"Steam 或其生产运行任务不存在";
        return NO;
    }
    if (!JobHasPID(kWindowServerLabel, NULL) ||
        !JobHasPID(kDisplayLabel, NULL)) {
        *message = @"请先启动 macOS GUI 与 DisplayStream";
        return NO;
    }

    pid_t steamPID = FindRunningSteamExecutable();
    if (steamPID > 1) {
        NSString *steamPath = RootExecutablePathForPID(steamPID);
        if (![steamPath isEqualToString:@(kSteamOuterExecutable)] &&
            ![steamPath isEqualToString:@(kSteamLiveExecutable)])
            steamPath = @(kSteamLiveExecutable);
        TrackApplicationSession(@"steam", steamPath, steamPID);
        pid_t windowOwner = FindSteamUIProcess(steamPID, YES);
        if (windowOwner > 1 &&
            RequestApplicationReopen(windowOwner, 2.0)) {
            os_unfair_lock_lock(&gStateLock);
            gActiveAppPID = steamPID;
            gActiveAppID = @"steam";
            os_unfair_lock_unlock(&gStateLock);
            HostLog(@"launch-app steam-reopen main=%d owner=%d result=ready",
                    steamPID, windowOwner);
            *message = @"Steam 已在运行，现有窗口已重新进入工作区";
            return YES;
        }
        // Runtime-confirmed on 2026-08-22: launchd reported the Steam job as
        // not running while a prior Dock launch still looked active and its
        // tile could not reopen a window.  A process is reusable only after
        // the real AppKit reopen transaction publishes a fresh window.  If
        // that fails, retire this exact executable before starting the same
        // production launchd job; do not report PID uptime as launch success.
        HostLog(@"launch-app steam-restart pid=%d reason=no-visible-window",
                steamPID);
        NSString *retireMessage = nil;
        if (!TerminateWindowlessRootExecutable(
                steamPID, steamPath, &retireMessage)) {
            *message = retireMessage ?: @"Steam 无窗口实例无法退出";
            return NO;
        }
        ApplicationSessionObservedExit(
            steamPID, @"steam", @"reopen-failed:exact-retire");
        NSDate *jobExitDeadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
        int staleJobPID = 0;
        while (jobExitDeadline.timeIntervalSinceNow > 0 &&
               JobHasPID(kSteamLabel, &staleJobPID) &&
               staleJobPID == steamPID) {
            usleep(50000);
        }
    }

    int jobPID = 0;
    BOOL jobLoaded = NO;
    (void)InspectJob(kSteamLabel, &jobPID, &jobLoaded);
    const char *startArgv[] = {kLaunchctl, "start", kSteamLabel, NULL};
    const char *loadArgv[] = {kLaunchctl, "load", kSteamPlist, NULL};
    int launchResult = jobLoaded
        ? RunCommand(startArgv, YES) : RunCommand(loadArgv, YES);
    if (launchResult != 0) {
        *message = [NSString stringWithFormat:
            @"Steam 生产任务启动失败（退出码 %d）", launchResult];
        return NO;
    }
    NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 + 20.0;
    do {
        steamPID = FindRunningSteamExecutable();
        if (steamPID > 1) break;
        usleep(100000);
    } while (NSDate.date.timeIntervalSince1970 < deadline);
    if (steamPID <= 1) {
        *message = @"Steam 生产任务已提交，但 20 秒内没有取得 steam_osx 进程";
        return NO;
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = steamPID;
    gActiveAppID = @"steam";
    os_unfair_lock_unlock(&gStateLock);
    NSString *steamPath = RootExecutablePathForPID(steamPID);
    TrackApplicationSession(@"steam",
        steamPath.length ? steamPath : @(kSteamLiveExecutable), steamPID);
    HostLog(@"launch-app process-ready id=steam pid=%d label=%s",
            steamPID, kSteamLabel);
    pid_t windowOwner = WaitForSteamUIProcess(steamPID, 30.0);
    if (windowOwner <= 1) {
        *message = @"Steam 主进程已启动，但 30 秒内没有 Helper 发布可用窗口";
        HostLog(@"launch-app steam-window result=timeout main=%d owner=absent",
                steamPID);
        return NO;
    }
    HostLog(@"launch-app steam-window result=ready main=%d owner=%d "
            "path=DisplayStream", steamPID, windowOwner);
    *message = @"Steam 已通过生产运行任务打开并发布窗口";
    return YES;
}

static BOOL PrepareSystemApplicationCode(NSString *rootPath,
                                         NSString **message) {
    // Runtime-confirmed: Calculator's BasicAndSci.calcview failed NSBundle
    // preflight, leaving normalSize: nil and a real 0x0 CalcWindow. Registering
    // the two stock plugin CodeDirectories (without altering either image)
    // made NSBundle load and the full calculator appear. Exec admission alone
    // cannot cover plugins dynamically selected by NSBundle later in launch.
    // TextEdit separately had a trusted stock main image but died in sandbox
    // exec policy; merging the existing MacWS profile admitted its real UI.
    BOOL systemApp = [rootPath hasPrefix:@"/System/Applications/"] ||
        [rootPath hasPrefix:@"/System/Library/CoreServices/"] ||
        [rootPath hasPrefix:@"/System/Volumes/Preboot/Cryptexes/App/System/Applications/"];
    if (!systemApp) return YES;
    NSRange mainImage = [rootPath rangeOfString:@".app/Contents/MacOS/"
                                      options:NSBackwardsSearch];
    if (mainImage.location == NSNotFound) return YES;
    NSString *bundle = [rootPath substringToIndex:mainImage.location + 4];
    // The helper preserves already-converted main images and all plugin
    // signatures. Only a main image missing the existing chroot profile gets
    // a backed-up, atomic first-use conversion; live trust is checked each
    // time. No rootfs scan or process-lifetime pathname success cache.
    const char *prepare[] = {
        "/var/jb/usr/bin/timeout", "-k", "2", "20",
        "/var/jb/usr/bin/python3", "/var/jb/usr/macOS/bin/macws_system_app_prepare.py",
        rootPath.fileSystemRepresentation, NULL,
    };
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    int result = RunCommandToLog(prepare, YES,
        "/var/mobile/Library/Logs/AppPluginTrust.host.log");
    HostLog(@"launch-app code-admission bundle=%@ result=%d seconds=%.3f",
            bundle, result, CFAbsoluteTimeGetCurrent() - began);
    if (result != 0) {
        *message = @"系统应用的启动策略或插件准入未完成，请查看 AppPluginTrust 日志";
        return NO;
    }
    return YES;
}

static BOOL RootApplicationRequiresNativeMetal(NSString *rootPath) {
    NSString *macOSDirectory = rootPath.stringByDeletingLastPathComponent;
    NSString *contents = macOSDirectory.stringByDeletingLastPathComponent;
    if (![macOSDirectory.lastPathComponent isEqualToString:@"MacOS"] ||
        ![contents.lastPathComponent isEqualToString:@"Contents"]) return NO;
    NSString *plistPath = [[@(kRootFS) stringByAppendingString:contents]
        stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    // The native device is a GUI-app launch contract, not a Geekbench-only
    // workaround. Word's mso40ui calls MTLCreateSystemDefaultDevice too; the
    // CPU profile returns nil there. Keep this boundary to real app bundles
    // with their own Info.plist, excluding arbitrary CLI tools and services.
    return [info isKindOfClass:[NSDictionary class]] && info.count != 0;
}

static BOOL LaunchRootExecutable(const char *identifier,
                                 NSString *rootPath,
                                 const char *logPath,
                                 NSTimeInterval timeout,
                                 BOOL documentOpenPending,
                                 NSString **message) {
    NSString *hostPath = [@("/var/mnt/rootfs") stringByAppendingString:rootPath];
    // access(X_OK) asks iPadOS whether this foreign-platform Mach-O may be
    // executed directly in the caller's native context.  AMFI correctly
    // answers EPERM for Finder even though launchdchrootexec can admit the
    // trusted image after entering the macOS root.  Validate the filesystem
    // invariant here; the real chroot launch remains the admission witness.
    if (!HasExecutableFileMode(hostPath.fileSystemRepresentation)) {
        *message = [NSString stringWithFormat:@"应用不存在或不可执行: %@",
                    rootPath];
        return NO;
    }
    if (!JobHasPID(kWindowServerLabel, NULL)) {
        *message = @"请先启动 macOS GUI";
        return NO;
    }


    pid_t existingPID = FindRunningRootExecutable(rootPath);
    if (existingPID > 1) {
        if (documentOpenPending) {
            BOOL endpointReady = WaitForAppInputEndpoint(
                existingPID, MIN(timeout, 5.0));
            if (!endpointReady) {
                HostLog(@"launch-document reuse pid=%d executable=%@ "
                        "result=no-appinput-endpoint", existingPID,
                        rootPath);
                *message = @"目标应用仍在运行，但文稿投递端点未就绪";
                return NO;
            }
            os_unfair_lock_lock(&gStateLock);
            gActiveAppPID = existingPID;
            gActiveAppID = [@(identifier) copy];
            os_unfair_lock_unlock(&gStateLock);
            TrackApplicationSession(@(identifier), rootPath, existingPID);
            HostLog(@"launch-document reuse id=%s pid=%d executable=%@ "
                    "endpoint=ready", identifier, existingPID, rootPath);
            *message = @"目标应用已在运行，文稿投递端点已就绪";
            return YES;
        }
        int exitStatus = -1;
        BOOL finder = strcmp(identifier, "finder") == 0;
        BOOL reopenLifecycle = strcmp(identifier, "system-settings") == 0 ||
                               strcmp(identifier, "maps") == 0;
        // System Settings and Maps own native reopen lifecycles.  Their
        // metrics sidecar may describe a window that has since closed if the
        // application main queue stopped publishing.  Require a fresh
        // generation produced after the exact reopen request; PID uptime or a
        // stale Visible bit is not a launch-success witness.
        // A current visible metrics entry is an immediate reuse witness; a
        // generic AppKit process with zero windows must receive the same real
        // reopen lifecycle as a Dock/open request before it is discarded.
        // Runtime-confirmed with Terminal pid 99506 on 2026-08-06: the app was
        // healthy and idle in NSApplication.run with a live AppInput endpoint,
        // and one ReopenApplication record published its normal Terminal
        // window. The old three-second metrics-only wait could never change a
        // windowless process and was followed by another three-second TERM
        // timeout. Use that upstream lifecycle for every ordinary AppKit app;
        // Finder retains its native Command-N browser transaction below.
        BOOL existingWindow = reopenLifecycle
            ? RequestApplicationReopen(existingPID, 8.0)
            : WaitForWindowMetrics(existingPID, 0.15, &exitStatus);
        if (existingWindow && strcmp(identifier, "system-settings") == 0)
            existingWindow = WaitForSystemSettingsContent(12.0);
        if (!existingWindow && finder)
            existingWindow = RequestFinderBrowserWindow(existingPID, 8.0);
        if (!existingWindow && !finder && !reopenLifecycle)
            // Runtime-confirmed on Terminal pid 14367 (2026-08-06): a
            // successful AppKit reopen publishes its window metrics within
            // 400 ms.  A zero-window instance that has not answered after one
            // second never answered during the old 2.5-second grace either;
            // the additional wait only delayed the replacement launch.
            existingWindow = RequestApplicationReopen(existingPID, 1.0);
        if (!existingWindow) {
            // Runtime-confirmed on the default Terminal bootstrap: closing
            // its last represented iPad Scene leaves a healthy process with
            // a valid zero-entry metrics header. Reusing that process can
            // never produce a Scene; spawning beside it violates the user's
            // one-application-instance model. Retire the windowless instance
            // first, then continue through the ordinary launch path below.
            if (!TerminateWindowlessRootExecutable(existingPID, rootPath,
                                                    message))
                return NO;
            existingPID = 0;
        } else {
            os_unfair_lock_lock(&gStateLock);
            gActiveAppPID = existingPID;
            gActiveAppID = [@(identifier) copy];
            os_unfair_lock_unlock(&gStateLock);
            TrackApplicationSession(@(identifier), rootPath, existingPID);
            HostLog(@"launch-app reuse id=%s pid=%d executable=%@ "
                    "identity=proc_pidpath",
                    identifier, existingPID, rootPath);
            *message = [NSString stringWithFormat:
                @"%s 已在运行，正在打开现有窗口", identifier];
            return YES;
        }
    }

    if (!PrepareSystemApplicationCode(rootPath, message)) return NO;

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int logFD = open(logPath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (logFD >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFD);
    }
    const char *rootExecutable = rootPath.fileSystemRepresentation;
    const char *ordinaryArgv[] = {kChrootExec, "0", "0", kRootFS,
                                  rootExecutable, NULL};
    const char *cleanStateArgv[] = {kChrootExec, "0", "0", kRootFS,
        rootExecutable, "-ApplePersistenceIgnoreState", "YES", NULL};
    BOOL cleanState = strcmp(identifier, "terminal") == 0 ||
                      strcmp(identifier, "finder") == 0;
    const char *const *argv = cleanState ? cleanStateArgv : ordinaryArgv;
    // Runtime-confirmed on 2026-08-02: Terminal's ordinary launch restored
    // two historical windows/tabs (including diagnostic text) and needed
    // 3.30 s to publish a usable window. With AppKit's persistence override it
    // published one clean window in 1.50 s. Finder likewise accumulated one
    // restored browser per prior test launch. Start both user-facing shell
    // apps cleanly; this changes their launch transaction upstream and does
    // not hide extra catalog entries or relax the real-window witness below.
    pid_t pid = 0;
    char **childEnvironment = environ;
    char **ownedEnvironment = NULL;
    const char *additions[8];
    size_t additionCount = 0;
    BOOL nativeAGX = strcmp(identifier, "glassdemo") == 0 ||
        RootApplicationRequiresNativeMetal(rootPath);
    if (nativeAGX) {
        additions[additionCount++] = "MACWS_AGX_NATIVE=1";
        additions[additionCount++] = "MACWS_AGX_REGISTER_CLASSES=1";
        HostLog(@"launch-metal-profile executable=%@ native=YES", rootPath);
    }
    if (strcmp(identifier, "terminal") == 0) {
        // Keep the Control Center/Dock launch transaction equivalent to the
        // production Terminal launchd job emitted by macos_gui.sh. Runtime on
        // Terminal pid 92921 proved that Host-v5 key events reached its real
        // TTView and bash stayed alive, while the captured window remained
        // blank for more than 40 seconds: this direct-spawn path had omitted
        // both of that job's display-clock contracts. The existing 750-ms
        // settle remains explicitly scoped/labeled as a Terminal usability
        // scaffold in AppInputBridge; this branch fixes launch-environment
        // drift rather than introducing another redraw mechanism.
        additions[additionCount++] = "CA_VSYNC_OFF=1";
        additions[additionCount++] = "MACWS_APP_DISPLAY_SETTLE_MS=750";
    }
    if (strcmp(identifier, "glassdemo") == 0 ||
        strcmp(identifier, "activity-monitor") == 0 ||
               strcmp(identifier, "finder") == 0 ||
               strcmp(identifier, "custom-path") == 0 ||
               IsThirdPartyAppIdentifier(identifier)) {
        // Runtime-confirmed by Amadine-2026-08-11-141854.ips: creating a
        // document made AppKit resolve a NIB image through NSWorkspace, which
        // dispatched LaunchServices bundle registration and recursively
        // finalized 511 CoreServicesInternal FileCache/CFURL frames when the
        // host mount escaped the chroot.  A controlled A/B with the complete
        // logical-root namespace produced the real canvas and no new crash.
        // Activity Monitor reaches the same root invariant while resolving a
        // sampled process icon: runtime-confirmed by
        // Activity Monitor-2026-08-12-010001.ips, whose crashing thread enters
        // NSWorkspace iconForFile: -> _LSFindOrRegisterBundleNode -> NSURL
        // bookmarkData -> CoreServicesInternal FileCache recursion until the
        // stack guard fires. Scope the filesystem contract to these proven
        // consumers. Finder's file-open A/B on 2026-09-07 reached the same
        // FileCache/CFURL recursion without this environment and reached the
        // real RunningBoard launch boundary with it. Finder keeps its own
        // clean-state and browser-window policy; this only supplies the
        // logical-root filesystem contract.
        additions[additionCount++] = "MACWS_APP_MOUNT_COMPAT=1";
    }
    if (additionCount) {
        ownedEnvironment = CopyEnvironmentAdding(additions, additionCount);
        if (!ownedEnvironment) {
            posix_spawn_file_actions_destroy(&actions);
            if (logFD >= 0) close(logFD);
            *message = @"无法为应用构造启动环境";
            return NO;
        }
        childEnvironment = ownedEnvironment;
    }
    int error = SpawnMacOSApplication(
        &pid, kChrootExec, &actions, (char *const *)argv, childEnvironment,
        YES);
    FreeCopiedEnvironment(ownedEnvironment);
    posix_spawn_file_actions_destroy(&actions);
    if (logFD >= 0) close(logFD);
    if (error != 0) {
        *message = [NSString stringWithFormat:@"拉起应用失败: %s", strerror(error)];
        return NO;
    }
    HostLog(@"launch-app id=%s pid=%d executable=%@", identifier, pid,
            rootPath);
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = pid;
    gActiveAppID = [@(identifier) copy];
    os_unfair_lock_unlock(&gStateLock);
    TrackApplicationSession(@(identifier), rootPath, pid);
    if (JobHasPID(kDisplayLabel, NULL)) {
        if (documentOpenPending) {
            BOOL endpointReady = WaitForAppInputEndpoint(pid,
                                                          MIN(timeout, 10.0));
            if (!endpointReady) {
                os_unfair_lock_lock(&gStateLock);
                if (gActiveAppPID == pid) {
                    gActiveAppPID = 0;
                    gActiveAppID = @"";
                }
                os_unfair_lock_unlock(&gStateLock);
                *message = @"目标应用已启动，但文稿投递端点未就绪";
                BeginApplicationChildReaper(pid, @(identifier));
                return NO;
            }
            HostLog(@"launch-document process-ready id=%s pid=%d "
                    "executable=%@ endpoint=ready", identifier, pid,
                    rootPath);
            *message = @"目标应用与文稿投递端点已就绪";
            BeginApplicationChildReaper(pid, @(identifier));
            return YES;
        }
        int exitStatus = -1;
        BOOL finder = strcmp(identifier, "finder") == 0;
        BOOL reopenLifecycle = strcmp(identifier, "system-settings") == 0 ||
                               strcmp(identifier, "maps") == 0;
        BOOL customPath = strcmp(identifier, "custom-path") == 0 ||
                          IsThirdPartyAppIdentifier(identifier);
        BOOL windowReady = NO;
        if (finder) {
            windowReady = RequestFinderBrowserWindow(pid, timeout);
        } else if (reopenLifecycle) {
            windowReady = RequestApplicationReopen(pid, timeout);
        } else if (customPath) {
            // Runtime-confirmed with Amadine pid 60156/60398 on 2026-08-11:
            // the application remained healthy with a live AppInput endpoint,
            // while its valid metrics catalog stayed at entryCount=0 for more
            // than one minute.  A bare executable launch has no LaunchServices
            // AppleEvent to perform the ordinary Dock/open lifecycle.  Give a
            // third-party app a chance to publish its initial NSWindow while
            // waiting for its endpoint, then deliver NSApplication reopen
            // process.  This is the same generic lifecycle used when reusing a
            // windowless process above, not an app-name exception or a
            // synthetic window-success witness.
            windowReady = WaitForInitialApplicationWindow(pid, timeout,
                                                           &exitStatus);
        } else {
            windowReady = WaitForWindowMetrics(pid, timeout, &exitStatus);
        }
        if (windowReady && strcmp(identifier, "system-settings") == 0)
            windowReady = WaitForSystemSettingsContent(12.0);
        if (!windowReady) {
            os_unfair_lock_lock(&gStateLock);
            if (gActiveAppPID == pid) {
                gActiveAppPID = 0;
                gActiveAppID = @"";
            }
            os_unfair_lock_unlock(&gStateLock);
            if (exitStatus >= 0 && WIFEXITED(exitStatus)) {
                *message = [NSString stringWithFormat:
                    @"%s 在发布 AppKit 窗口前退出（状态 %d）",
                    identifier, WEXITSTATUS(exitStatus)];
            } else if (exitStatus >= 0 && WIFSIGNALED(exitStatus)) {
                *message = [NSString stringWithFormat:
                    @"%s 在发布 AppKit 窗口前被信号 %d 终止",
                    identifier, WTERMSIG(exitStatus)];
            } else {
                *message = [NSString stringWithFormat:
                    @"%s 已启动，但 %.0f 秒内没有发布可捕获的 AppKit 窗口",
                    identifier, timeout];
            }
            BeginApplicationChildReaper(pid, @(identifier));
            return NO;
        }
        HostLog(@"launch-app window-ready id=%s pid=%d path=DisplayStream",
                identifier, pid);
    } else {
        *message = @"DisplayStream 服务未运行";
        BeginApplicationChildReaper(pid, @(identifier));
        return NO;
    }
    BeginApplicationChildReaper(pid, @(identifier));
    return YES;
}

static NSString *ResolveExecutableRootPath(const char *requestedPath,
                                           NSString **errorOut) {
    if (!requestedPath || requestedPath[0] != '/' ||
        strlen(requestedPath) >= PATH_MAX) {
        if (errorOut) *errorOut = @"请输入 macOS 绝对路径";
        return nil;
    }
    NSString *rootPath = [@(requestedPath) stringByStandardizingPath];
    NSString *hostPath = [@("/var/mnt/rootfs") stringByAppendingString:rootPath];
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:hostPath
                                            isDirectory:&directory]) {
        if (errorOut) *errorOut = @"路径不存在";
        return nil;
    }
    if (directory) {
        NSString *plistPath = [hostPath stringByAppendingPathComponent:
            @"Contents/Info.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        NSString *executable = plist[@"CFBundleExecutable"];
        if (!executable.length) {
            if (errorOut) *errorOut = @"该目录不是可启动的 macOS App";
            return nil;
        }
        rootPath = [[rootPath stringByAppendingPathComponent:@"Contents/MacOS"]
            stringByAppendingPathComponent:executable];
        hostPath = [@("/var/mnt/rootfs") stringByAppendingString:rootPath];
    }
    char resolvedRoot[PATH_MAX] = {0};
    char resolved[PATH_MAX] = {0};
    if (!realpath("/var/mnt/rootfs", resolvedRoot)) {
        HostLog(@"launch-path reject stage=root-realpath errno=%d (%s)",
                errno, strerror(errno));
        if (errorOut) *errorOut = @"解析后的文件不可执行";
        return nil;
    }
    if (!realpath(hostPath.fileSystemRepresentation, resolved)) {
        HostLog(@"launch-path reject stage=target-realpath path=%@ errno=%d (%s)",
                hostPath, errno, strerror(errno));
        if (errorOut) *errorOut = @"解析后的文件不可执行";
        return nil;
    }
    size_t rootLength = strlen(resolvedRoot);
    // iPadOS canonicalizes /var to /private/var.  Compare two canonical paths
    // and require a component boundary: the old literal-prefix check rejected
    // every valid app, while a boundary-less prefix would admit sibling paths
    // such as /private/var/mnt/rootfs-escape.
    struct stat executableStatus = {0};
    BOOL executableFile = stat(resolved, &executableStatus) == 0 &&
        S_ISREG(executableStatus.st_mode) &&
        (executableStatus.st_mode & (S_IXUSR | S_IXGRP | S_IXOTH)) != 0;
    if (strncmp(resolved, resolvedRoot, rootLength) != 0 ||
        resolved[rootLength] != '/' || !executableFile) {
        HostLog(@"launch-path reject stage=boundary-or-mode root=%s "
                "target=%s boundary=%d mode=%#o errno=%d (%s)",
                resolvedRoot, resolved, (int)(unsigned char)resolved[rootLength],
                executableStatus.st_mode, errno, strerror(errno));
        if (errorOut) *errorOut = @"解析后的文件不可执行";
        return nil;
    }
    HostLog(@"launch-path accepted requested=%s executable=%s",
            requestedPath, resolved + rootLength);
    return [NSString stringWithUTF8String:resolved + rootLength];
}

static BOOL LaunchAllowedApp(const char *identifier, NSString **message);

static BOOL LaunchGeekbench(NSString **message) {
    NSString *rootPath = @(kGeekbenchExecutable);
    NSString *hostPath = [@(kRootFS) stringByAppendingString:rootPath];
    if (access(kGeekbenchPlist, R_OK) != 0 ||
        !HasExecutableFileMode(hostPath.fileSystemRepresentation)) {
        *message = @"Geekbench 6 或独立启动任务不存在";
        return NO;
    }
    if (!JobHasPID(kWindowServerLabel, NULL) ||
        !JobHasPID(kDisplayLabel, NULL)) {
        *message = @"请先启动 macOS GUI 与 DisplayStream";
        return NO;
    }

    int jobPID = 0;
    BOOL jobLoaded = NO;
    (void)InspectJob(kGeekbenchLabel, &jobPID, &jobLoaded);
    pid_t legacyPID = FindRunningRootExecutable(rootPath);
    if (legacyPID > 1 && legacyPID != jobPID) {
        // A pre-upgrade direct spawn still belongs to hostd's coalition.
        // Never silently reuse that process and claim the CPU fix is active.
        // Do not interrupt a benchmark already running in the old session.
        if (FindRunningRootExecutable(@(kGeekbenchBackendExecutable)) > 1) {
            *message = @"旧 Geekbench 会话正在跑分；请等本轮结束后再打开";
            return NO;
        }
        HostLog(@"launch-app geekbench retire-legacy pid=%d signal=TERM",
                legacyPID);
        if (kill(legacyPID, SIGTERM) != 0 && errno != ESRCH) {
            *message = @"旧 Geekbench 会话无法退出";
            return NO;
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
        while (deadline.timeIntervalSinceNow > 0 &&
               kill(legacyPID, 0) == 0) usleep(50000);
        if (kill(legacyPID, 0) == 0) {
            *message = @"旧 Geekbench 会话仍在退出，请稍后重试";
            return NO;
        }
    }

    if (jobPID <= 1) {
        const char *startArgv[] = {kLaunchctl, "start", kGeekbenchLabel, NULL};
        const char *loadArgv[] = {kLaunchctl, "load", kGeekbenchPlist, NULL};
        int result = RunCommand(jobLoaded ? startArgv : loadArgv, YES);
        if (result != 0 || !WaitForJobPID(kGeekbenchLabel, 8.0, &jobPID)) {
            *message = [NSString stringWithFormat:
                @"Geekbench 独立任务启动失败（状态 %d）", result];
            return NO;
        }
    }
    // launchctl can briefly expose launchdchrootexec before its final exec.
    // The live job PID must become the exact benchmark GUI, not merely exist.
    NSDate *execDeadline = [NSDate dateWithTimeIntervalSinceNow:5.0];
    while (execDeadline.timeIntervalSinceNow > 0 &&
           ![RootExecutablePathForPID(jobPID) isEqualToString:rootPath]) {
        if (kill(jobPID, 0) != 0) break;
        usleep(50000);
    }
    if (![RootExecutablePathForPID(jobPID) isEqualToString:rootPath]) {
        *message = @"Geekbench 独立任务没有进入实际 GUI 程序";
        return NO;
    }
    int exitStatus = -1;
    BOOL windowReady = WaitForWindowMetrics(jobPID, 8.0, &exitStatus);
    if (!windowReady)
        windowReady = RequestApplicationReopen(jobPID, 3.0);
    if (!windowReady) {
        *message = @"Geekbench 已启动，但没有发布可显示的窗口";
        return NO;
    }
    os_unfair_lock_lock(&gStateLock);
    gActiveAppPID = jobPID;
    gActiveAppID = @"geekbench";
    os_unfair_lock_unlock(&gStateLock);
    TrackApplicationSession(@"geekbench", rootPath, jobPID);
    HostLog(@"launch-app geekbench pid=%d job=%s path=dedicated-launchd-job",
            jobPID, kGeekbenchLabel);
    *message = @"Geekbench 窗口已就绪";
    return YES;
}

static BOOL LaunchRequestedPath(const char *requestedPath,
                                BOOL documentOpenPending,
                                NSString **message) {
    NSString *error = nil;
    NSString *rootPath = ResolveExecutableRootPath(requestedPath, &error);
    if (!rootPath) {
        *message = error ?: @"无法解析路径";
        return NO;
    }
    // A Dock tile and Control Center must enter the same application launch
    // transaction.  Preserve the special lifecycle already proven for Maps,
    // VS Code, System Settings, Finder and the other packaged apps instead of
    // reducing a resolved bundle URL to a bare generic exec.
    if ([rootPath isEqualToString:@(kVSCodeExecutable)] ||
        [rootPath isEqualToString:@(kVSCodeBundleExecutable)])
        return LaunchAllowedApp("vscode", message);
    if ([rootPath isEqualToString:@(kGeekbenchExecutable)])
        return LaunchGeekbench(message);
    if ([rootPath isEqualToString:@(kAsphaltExecutable)])
        return LaunchAllowedApp("asphalt", message);
    if ([rootPath isEqualToString:@(kWeatherExecutable)])
        return LaunchAllowedApp("weather", message);
    if ([rootPath isEqualToString:@(kSteamOuterExecutable)] ||
        [rootPath isEqualToString:@(kSteamLiveExecutable)])
        return LaunchAllowedApp("steam", message);
    for (NSUInteger index = 0;
         index < sizeof(kAllowedApps) / sizeof(kAllowedApps[0]); index++) {
        if ([rootPath isEqualToString:@(kAllowedApps[index].rootPath)])
            return LaunchAllowedApp(kAllowedApps[index].identifier, message);
    }
    return LaunchRootExecutable("custom-path", rootPath,
        "/var/mobile/Library/Logs/CustomApp.host.log", 30.0,
        documentOpenPending, message);
}

static BOOL LaunchAllowedApp(const char *identifier, NSString **message) {
    if (identifier && strcmp(identifier, "vscode") == 0)
        return LaunchVSCode(message);
    if (identifier && strcmp(identifier, "maps") == 0)
        return LaunchMapsViaUIKitCarrier(message);
    if (identifier && strcmp(identifier, "weather") == 0)
        return LaunchWeatherViaUIKitCarrier(message);
    if (identifier && strcmp(identifier, "steam") == 0)
        return LaunchSteam(message);
    if (identifier && strcmp(identifier, "asphalt") == 0)
        return LaunchAsphaltViaUIKitCarrier(message);
    const AllowedApp *app = NULL;
    for (NSUInteger i = 0; i < sizeof(kAllowedApps) / sizeof(kAllowedApps[0]); i++) {
        if (identifier && strcmp(identifier, kAllowedApps[i].identifier) == 0) {
            app = &kAllowedApps[i];
            break;
        }
    }
    if (!app) {
        *message = @"应用标识不在白名单中";
        return NO;
    }
    if (strcmp(identifier, "system-settings") == 0) {
        if (!EnsureRunningBoardSettingsBridge(message)) return NO;
        if (!EnsureSystemSettingsExtensionRuntime(message)) return NO;
        BOOL repaired = NO;
        if (!EnsureSystemSettingsCatalog(&repaired, message)) return NO;
        if (repaired) {
            NSString *rootPath = @(app->rootPath);
            pid_t cachedPID = FindRunningRootExecutable(rootPath);
            if (!RetireRootExecutableForCatalogRefresh(
                    cachedPID, rootPath, message)) return NO;
        }
    }
    if (!LaunchRootExecutable(identifier, @(app->rootPath), app->logPath,
                              30.0, NO, message)) return NO;
    if (strcmp(identifier, "glassdemo") == 0) {
        *message = @"GlassDemo 窗口已就绪；从窗口列表打开后即可直接触控";
    } else {
        *message = [NSString stringWithFormat:
            @"已启动 %s，AppKit 窗口已进入 DisplayStream 列表", identifier];
    }
    return YES;
}

static NSArray<NSString *> *ValidatedDocumentPaths(
        xpc_object_t request, NSString **message) {
    xpc_object_t values = xpc_dictionary_get_value(
        request, MACWS_CONTROL_KEY_DOCUMENT_PATHS);
    if (!values || xpc_get_type(values) != XPC_TYPE_ARRAY) {
        if (message) *message = @"缺少文稿路径列表";
        return nil;
    }
    size_t count = xpc_array_get_count(values);
    if (count == 0 || count > 128) {
        if (message) *message = @"文稿数量必须在 1 到 128 之间";
        return nil;
    }
    char resolvedRoot[PATH_MAX] = {0};
    if (!realpath(kRootFS, resolvedRoot)) {
        if (message) *message = @"无法解析 macOS 根目录";
        return nil;
    }
    size_t rootLength = strlen(resolvedRoot);
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:count];
    for (size_t index = 0; index < count; index++) {
        xpc_object_t value = xpc_array_get_value(values, index);
        const char *requested = value && xpc_get_type(value) == XPC_TYPE_STRING
            ? xpc_string_get_string_ptr(value) : NULL;
        if (!requested || requested[0] != '/' ||
            strlen(requested) >= PATH_MAX) {
            if (message) *message = @"文稿路径不是有效的 macOS 绝对路径";
            return nil;
        }
        NSString *rootPath = [@(requested) stringByStandardizingPath];
        NSString *hostPath = [@(kRootFS) stringByAppendingString:rootPath];
        char resolved[PATH_MAX] = {0};
        struct stat status = {0};
        if (!realpath(hostPath.fileSystemRepresentation, resolved) ||
            strncmp(resolved, resolvedRoot, rootLength) != 0 ||
            resolved[rootLength] != '/' || stat(resolved, &status) != 0 ||
            !S_ISREG(status.st_mode)) {
            HostLog(@"open-documents reject index=%zu requested=%s "
                    "resolved=%s errno=%d (%s)", index, requested,
                    resolved[0] ? resolved : "(none)", errno,
                    strerror(errno));
            if (message) *message = @"文稿不在受控 macOS 根目录内，或不是普通文件";
            return nil;
        }
        [paths addObject:rootPath];
    }
    return paths;
}

static BOOL WriteAllBytes(int descriptor, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length != 0) {
        ssize_t count = write(descriptor, cursor, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        cursor += (size_t)count;
        length -= (size_t)count;
    }
    return YES;
}

static void OpenDocumentHostPaths(pid_t targetPID, uint64_t nonce,
                                  char *sidecar, size_t sidecarSize,
                                  char *ack, size_t ackSize) {
    snprintf(sidecar, sidecarSize, "%s%s.%d.%016llx.plist", kRootFS,
             MACWS_OPEN_DOCUMENT_SIDECAR_PREFIX, targetPID,
             (unsigned long long)nonce);
    snprintf(ack, ackSize, "%s%s_ack.%d.%016llx.bin", kRootFS,
             MACWS_OPEN_DOCUMENT_SIDECAR_PREFIX, targetPID,
             (unsigned long long)nonce);
}

static BOOL PublishOpenDocumentSidecar(pid_t targetPID, uint64_t nonce,
                                       NSArray<NSString *> *paths,
                                       char *sidecarOut,
                                       size_t sidecarOutSize,
                                       NSString **message) {
    char ack[PATH_MAX] = {0};
    OpenDocumentHostPaths(targetPID, nonce, sidecarOut, sidecarOutSize,
                          ack, sizeof(ack));
    NSDictionary *payload = @{
        @"version": @1,
        @"nonce": @(nonce),
        @"target_pid": @(targetPID),
        @"paths": paths,
    };
    NSError *serializationError = nil;
    NSData *data = [NSPropertyListSerialization
        dataWithPropertyList:payload
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:&serializationError];
    if (!data) {
        if (message) *message = [NSString stringWithFormat:
            @"无法构造文稿投递数据：%@",
            serializationError.localizedDescription ?: @"未知错误"];
        return NO;
    }
    char temporary[PATH_MAX] = {0};
    int pathLength = snprintf(temporary, sizeof(temporary), "%s.new.%d",
                              sidecarOut, getpid());
    if (pathLength <= 0 || (size_t)pathLength >= sizeof(temporary)) {
        if (message) *message = @"文稿投递路径过长";
        return NO;
    }
    (void)unlink(temporary);
    (void)unlink(sidecarOut);
    (void)unlink(ack);
    int descriptor = open(temporary,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) {
        if (message) *message = [NSString stringWithFormat:
            @"无法创建文稿投递数据（errno=%d）", errno];
        return NO;
    }
    BOOL written = WriteAllBytes(descriptor, data.bytes, data.length) &&
        fsync(descriptor) == 0;
    int savedError = written ? 0 : (errno ?: EIO);
    if (close(descriptor) != 0 && written) {
        written = NO;
        savedError = errno;
    }
    if (written && rename(temporary, sidecarOut) != 0) {
        written = NO;
        savedError = errno;
    }
    if (!written) {
        (void)unlink(temporary);
        if (message) *message = [NSString stringWithFormat:
            @"无法发布文稿投递数据（errno=%d）", savedError];
    }
    return written;
}

static BOOL WaitForOpenDocumentAck(pid_t targetPID, uint64_t nonce,
                                   uint32_t expectedCount,
                                   NSTimeInterval timeout) {
    char sidecar[PATH_MAX] = {0};
    char ackPath[PATH_MAX] = {0};
    OpenDocumentHostPaths(targetPID, nonce, sidecar, sizeof(sidecar),
                          ackPath, sizeof(ackPath));
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    BOOL accepted = NO;
    while (deadline.timeIntervalSinceNow > 0) {
        int descriptor = open(ackPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor >= 0) {
            MacWSOpenDocumentAck ack = {0};
            struct stat status = {0};
            ssize_t count = read(descriptor, &ack, sizeof(ack));
            BOOL complete = fstat(descriptor, &status) == 0 &&
                count == (ssize_t)sizeof(ack) &&
                status.st_size == (off_t)sizeof(ack) &&
                S_ISREG(status.st_mode) && status.st_nlink == 1 &&
                (status.st_mode & 022) == 0;
            close(descriptor);
            if (complete && ack.magic == MACWS_OPEN_DOCUMENT_ACK_MAGIC &&
                ack.version == MACWS_OPEN_DOCUMENT_ACK_VERSION &&
                ack.size == sizeof(ack) && ack.nonce == nonce &&
                ack.targetPID == targetPID &&
                ack.acceptedCount == expectedCount) {
                accepted = YES;
                break;
            }
        }
        if (kill(targetPID, 0) != 0 && errno == ESRCH) break;
        usleep(20000);
    }
    (void)unlink(ackPath);
    if (!accepted) (void)unlink(sidecar);
    return accepted;
}

static NSString *ResolveImportedDocumentApplication(NSString *path,
                                                     NSString **message) {
    // Resolve inside macOS LaunchServices, not against iOS's file handlers.
    // This subprocess only resolves; it must not call hostd while hostd waits.
    NSString *output = [@"/tmp/macws-document-handler-"
        stringByAppendingFormat:@"%@.plist", NSUUID.UUID.UUIDString];
    NSString *hostOutput = [@(kRootFS) stringByAppendingString:output];
    const char *arguments[] = {
        "/var/jb/usr/bin/timeout", "-k", "2", "15",
        "/var/jb/usr/macOS/bin/launchdchrootexec", "0", "0", kRootFS,
        "/usr/local/bin/macwsworkspacectl", "resolve-document",
        path.fileSystemRepresentation, output.fileSystemRepresentation, NULL
    };
    int result = RunCommand(arguments, YES);
    NSDictionary *resolved = result == 0
        ? [NSDictionary dictionaryWithContentsOfFile:hostOutput] : nil;
    (void)unlink(hostOutput.fileSystemRepresentation);
    NSString *application = [resolved[@"application_path"]
        isKindOfClass:NSString.class] ? resolved[@"application_path"] : nil;
    if (![resolved[@"document_path"] isEqual:path] ||
        !application.isAbsolutePath) {
        if (message) *message = @"macOS 没有找到此文件的打开方式；导入副本仍保留在 MacWS Imports 中";
        return nil;
    }
    HostLog(@"open-in resolve document=%@ application=%@", path, application);
    return application;
}

static BOOL OpenDocumentsRequest(xpc_object_t request, pid_t *targetPIDOut,
                                 NSString **message) {
    NSArray<NSString *> *paths = ValidatedDocumentPaths(request, message);
    if (!paths) return NO;
    const char *applicationPath = xpc_dictionary_get_string(
        request, MACWS_CONTROL_KEY_APP_PATH);
    NSString *resolvedApplication = nil;
    if (!applicationPath || !*applicationPath) {
        // Open-In submits one imported document per transaction. Finder's
        // existing explicit-app, multi-document transaction is unchanged.
        if (paths.count != 1 ||
            ![paths.firstObject hasPrefix:@"/Users/Shared/MacWS Imports/"]) {
            if (message) *message = @"自动打开方式仅接受一个已导入的文稿";
            return NO;
        }
        resolvedApplication = ResolveImportedDocumentApplication(
            paths.firstObject, message);
        if (!resolvedApplication) return NO;
        applicationPath = resolvedApplication.fileSystemRepresentation;
    }
    if (!LaunchRequestedPath(applicationPath, YES, message)) return NO;
    os_unfair_lock_lock(&gStateLock);
    pid_t targetPID = gActiveAppPID;
    os_unfair_lock_unlock(&gStateLock);
    if (targetPID <= 1 || !WaitForAppInputEndpoint(targetPID, 2.0)) {
        if (message) *message = @"目标应用没有可用的 AppKit 文稿端点";
        return NO;
    }
    uint64_t nonce = 0;
    do {
        nonce = ((uint64_t)arc4random() << 32) | arc4random();
    } while (nonce == 0);
    char sidecar[PATH_MAX] = {0};
    if (!PublishOpenDocumentSidecar(targetPID, nonce, paths, sidecar,
                                    sizeof(sidecar), message)) return NO;
    static _Atomic uint32_t sequence = 0;
    MacWSInputRecord record = {
        .magic = MACWS_INPUT_MAGIC,
        .version = MACWS_INPUT_VERSION,
        .kind = MacWSInputKindOpenDocuments,
        .sceneID = nonce,
        .x = 0.0f,
        .y = 0.0f,
        .frameWidth = 1,
        .frameHeight = 1,
        .targetPID = targetPID,
        .source = MacWSInputSourceUnknown,
        .sampleSequence = atomic_fetch_add(&sequence, 1) + 1,
    };
    int sendError = 0;
    if (!SendAppInputRecord(targetPID, &record, &sendError)) {
        (void)unlink(sidecar);
        if (message) *message = [NSString stringWithFormat:
            @"无法投递 AppKit 文稿事件（errno=%d）", sendError];
        return NO;
    }
    // The acknowledgement is written only after the target's real AppKit
    // delegate returns. Runtime witness 1788787445.832..1788787453.912 showed
    // Preview opening the document while the former eight-second deadline
    // expired first; the subsequent window was published at 1788787468.522.
    // Keep the success criterion unchanged and wait for that real handler
    // completion through a cold-launch-sized bounded interval.
    BOOL accepted = WaitForOpenDocumentAck(
        targetPID, nonce, (uint32_t)paths.count, 30.0);
    HostLog(@"open-documents app=%s pid=%d nonce=%016llx count=%lu "
            "result=%@", applicationPath ?: "(nil)", targetPID,
            (unsigned long long)nonce, (unsigned long)paths.count,
            accepted ? @"appkit-accepted" : @"ack-timeout");
    if (!accepted) {
        if (message) *message = @"目标应用没有确认 AppKit 文稿事件";
        return NO;
    }
    if (targetPIDOut) *targetPIDOut = targetPID;
    if (message) *message = [NSString stringWithFormat:
        @"已由目标应用接收 %lu 个文稿", (unsigned long)paths.count];
    return YES;
}

static BOOL IsSteamSemaphoreName(const char *name) {
    if (!name || strnlen(name, 112) >= 112) return NO;
    return strncmp(name, "/BSem/", 6) == 0 ||
        strncmp(name, "/Evt/", 5) == 0 ||
        strncmp(name, "/MTX/", 5) == 0;
}

static BOOL IsSteamSemaphoreOperation(const char *operation) {
    return operation &&
        (!strcmp(operation, MACWS_STEAM_SEM_OP_OPEN) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_RECREATE) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_CLOSE) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_UNLINK) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_RESET) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_DELAY) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_TRYWAIT) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_WAIT_POLL) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_POST) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_GETVALUE) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_REGISTER_WAIT) ||
         !strcmp(operation, MACWS_STEAM_SEM_OP_NOTIFY));
}

static BOOL IsSteamMachRendezvousName(const char *name) {
    static const char prefix[] = MACWS_STEAM_MACH_RENDEZVOUS_PREFIX;
    if (!name || strncmp(name, prefix, sizeof(prefix) - 1) != 0 ||
        strnlen(name, 128) >= 128) return NO;
    const char *suffix = name + sizeof(prefix) - 1;
    if (!*suffix) return NO;
    for (const char *cursor = suffix; *cursor; cursor++) {
        if (*cursor < '0' || *cursor > '9') return NO;
    }
    return YES;
}

static BOOL IsSteamMachRendezvousOperation(const char *operation) {
    return operation &&
        (!strcmp(operation, MACWS_STEAM_MACH_OP_REGISTER) ||
         !strcmp(operation, MACWS_STEAM_MACH_OP_LOOKUP));
}

static BOOL ReplySteamMachRendezvous(xpc_object_t request, int error,
                                     mach_port_t sendPort) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    if (!peer || !reply) return NO;
    xpc_dictionary_set_int64(reply, MACWS_STEAM_MACH_KEY_ERROR, error);
    if (error == 0 && MACH_PORT_VALID(sendPort))
        xpc_dictionary_set_mach_send(
            reply, MACWS_STEAM_MACH_KEY_PORT, sendPort);
    xpc_connection_send_message(peer, reply);
    return YES;
}

static void ServeSteamMachRendezvousRequest(xpc_object_t request,
                                            const char *operation) {
    const char *name = xpc_dictionary_get_string(
        request, MACWS_STEAM_MACH_KEY_NAME);
    if (!IsSteamMachRendezvousName(name)) {
        ReplySteamMachRendezvous(request, EINVAL, MACH_PORT_NULL);
        return;
    }
    NSString *key = @(name);
    BOOL registerOperation =
        !strcmp(operation, MACWS_STEAM_MACH_OP_REGISTER);
    mach_port_t registeredPort = registerOperation
        ? xpc_dictionary_copy_mach_send(
            request, MACWS_STEAM_MACH_KEY_PORT)
        : MACH_PORT_NULL;
    if (registerOperation && !MACH_PORT_VALID(registeredPort)) {
        ReplySteamMachRendezvous(request, EINVAL, MACH_PORT_NULL);
        return;
    }

    dispatch_async(gSteamMachRendezvousQueue, ^{
        if (registerOperation) {
            NSNumber *previous = gSteamMachRendezvousPorts[key];
            if (!previous && gSteamMachRendezvousPorts.count >= 64) {
                // PID-qualified entries cannot be reused by a later browser.
                // Keep the broker bounded across repeated failed launches.
                NSString *oldest = gSteamMachRendezvousPorts.allKeys.firstObject;
                NSNumber *stale = oldest
                    ? gSteamMachRendezvousPorts[oldest] : nil;
                if (oldest) [gSteamMachRendezvousPorts removeObjectForKey:oldest];
                if (stale && MACH_PORT_VALID(stale.unsignedIntValue))
                    (void)mach_port_deallocate(
                        mach_task_self(), stale.unsignedIntValue);
            }
            if (previous && MACH_PORT_VALID(previous.unsignedIntValue))
                (void)mach_port_deallocate(
                    mach_task_self(), previous.unsignedIntValue);
            gSteamMachRendezvousPorts[key] = @(registeredPort);
            HostLog(@"Steam Mach rendezvous registered name=%@ port=%u",
                    key, registeredPort);
            ReplySteamMachRendezvous(request, 0, MACH_PORT_NULL);
            return;
        }

        NSNumber *stored = gSteamMachRendezvousPorts[key];
        mach_port_t sendPort = stored
            ? (mach_port_t)stored.unsignedIntValue : MACH_PORT_NULL;
        if (!MACH_PORT_VALID(sendPort)) {
            ReplySteamMachRendezvous(request, ENOENT, MACH_PORT_NULL);
            return;
        }
        HostLog(@"Steam Mach rendezvous lookup name=%@ port=%u",
                key, sendPort);
        ReplySteamMachRendezvous(request, 0, sendPort);
    });
}

static BOOL WriteSteamSemaphoreWaitReply(int descriptor, int error,
                                         uint64_t generation,
                                         uint32_t value,
                                         uint64_t requestID) {
    MacWSSteamSemaphoreWaitReply reply = {
        .magic = MACWS_STEAM_SEM_WAIT_MAGIC,
        .version = MACWS_STEAM_SEM_VERSION,
        .error = error,
        .value = value,
        .generation = generation,
        .requestID = requestID,
    };
    const uint8_t *cursor = (const uint8_t *)&reply;
    size_t remaining = sizeof(reply);
    while (remaining != 0) {
        ssize_t amount = write(descriptor, cursor, remaining);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) return NO;
        cursor += (size_t)amount;
        remaining -= (size_t)amount;
    }
    return YES;
}

static uint64_t SteamSemaphoreHash(const char *name) {
    uint64_t hash = UINT64_C(1469598103934665603);
    for (const unsigned char *cursor = (const unsigned char *)name;
         *cursor; cursor++) {
        hash ^= *cursor;
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static void SteamSemaphoreHostPath(const MacWSSteamSemaphoreEntry *entry,
                                   char *path, size_t pathSize) {
    snprintf(path, pathSize,
             "/var/mnt/rootfs/private/tmp/"
             ".macws-steam-sem-%016llx-%016llx",
             (unsigned long long)SteamSemaphoreHash(entry->name),
             (unsigned long long)entry->generation);
}

static int CreateSteamSemaphoreState(MacWSSteamSemaphoreEntry *entry,
                                     uint32_t initialValue) {
    char path[PATH_MAX] = {0};
    SteamSemaphoreHostPath(entry, path, sizeof(path));
    int descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC,
                          0600);
    if (descriptor < 0) return errno;
    MacWSSteamSemaphoreState state = {
        .magic = MACWS_STEAM_SEM_STATE_MAGIC,
        .version = MACWS_STEAM_SEM_STATE_VERSION,
        .value = initialValue,
        .revision = 1,
        .brokerGeneration = entry->generation,
    };
    strlcpy(state.name, entry->name, sizeof(state.name));
    int error = 0;
    if (fchown(descriptor, 501, 501) != 0 ||
        fchmod(descriptor, 0600) != 0 ||
        pwrite(descriptor, &state, sizeof(state), 0) !=
            (ssize_t)sizeof(state) ||
        ftruncate(descriptor, sizeof(state)) != 0)
        error = errno ?: EIO;
    if (error == 0) entry->stateDescriptor = descriptor;
    else {
        close(descriptor);
        (void)unlink(path);
    }
    return error;
}

static int LockSteamSemaphoreState(MacWSSteamSemaphoreEntry *entry,
                                   MacWSSteamSemaphoreState *state) {
    if (!entry || entry->stateDescriptor < 0 || !state) return EINVAL;
    // A blocking flock waiter in the macOS runtime was runtime-confirmed not
    // to resume after a cross-runtime unlock. Keep both sides on the same
    // nonblocking predicate. The lock spans only one fixed-size pread/pwrite.
    for (uint32_t attempt = 0; attempt < 20000; attempt++) {
        if (flock(entry->stateDescriptor, LOCK_EX | LOCK_NB) == 0) break;
        int lockError = errno;
        if (lockError != EWOULDBLOCK && lockError != EAGAIN &&
            lockError != EINTR) return lockError;
        if (attempt == 19999) return ETIMEDOUT;
        if (attempt < 32) sched_yield();
        else usleep(250);
    }
    ssize_t amount = pread(entry->stateDescriptor, state, sizeof(*state), 0);
    if (amount != (ssize_t)sizeof(*state) ||
        state->magic != MACWS_STEAM_SEM_STATE_MAGIC ||
        state->version != MACWS_STEAM_SEM_STATE_VERSION ||
        state->brokerGeneration != entry->generation ||
        strcmp(state->name, entry->name) ||
        state->waiterCount > MACWS_STEAM_SEM_WAITER_CAPACITY) {
        (void)flock(entry->stateDescriptor, LOCK_UN);
        return amount < 0 ? errno : EPROTO;
    }
    entry->value = state->value;
    return 0;
}

static int StoreAndUnlockSteamSemaphoreState(
        MacWSSteamSemaphoreEntry *entry,
        MacWSSteamSemaphoreState *state) {
    if (!entry || entry->stateDescriptor < 0 || !state) return EINVAL;
    state->revision++;
    ssize_t amount = pwrite(
        entry->stateDescriptor, state, sizeof(*state), 0);
    int result = amount == (ssize_t)sizeof(*state) ? 0 : (errno ?: EIO);
    entry->value = state->value;
    if (flock(entry->stateDescriptor, LOCK_UN) != 0 && result == 0)
        result = errno ?: EIO;
    return result;
}

static void UnlockSteamSemaphoreState(MacWSSteamSemaphoreEntry *entry) {
    if (entry && entry->stateDescriptor >= 0)
        (void)flock(entry->stateDescriptor, LOCK_UN);
}

static uint32_t SteamSemaphoreHostWaiterCount(
        const MacWSSteamSemaphoreEntry *entry) {
    if (!entry) return 0;
    uint64_t count = entry->waiterSocketCount;
    for (uint32_t index = 0; index < entry->pollingWaiterCount; index++)
        if (!entry->pollingWaiterGranted[index]) count++;
    return count > MACWS_STEAM_SEM_WAITER_CAPACITY ?
        MACWS_STEAM_SEM_WAITER_CAPACITY : (uint32_t)count;
}

static void UnlinkSteamSemaphoreState(
        const MacWSSteamSemaphoreEntry *entry) {
    char path[PATH_MAX] = {0};
    SteamSemaphoreHostPath(entry, path, sizeof(path));
    (void)unlink(path);
}

static void DestroySteamSemaphoreEntry(MacWSSteamSemaphoreEntry *entry) {
    if (!entry) return;
    for (uint32_t index = 0; index < entry->waiterCount; index++) {
        if (MACH_PORT_VALID(entry->waiterPorts[index]))
            (void)mach_port_deallocate(
                mach_task_self(), entry->waiterPorts[index]);
    }
    for (uint32_t index = 0; index < entry->waiterSocketCount; index++) {
        int descriptor = entry->waiterSockets[index];
        (void)WriteSteamSemaphoreWaitReply(
            descriptor, ECANCELED, entry->generation, entry->value,
            entry->waiterSocketRequestIDs[index]);
        close(descriptor);
    }
    if (entry->stateDescriptor >= 0) close(entry->stateDescriptor);
    free(entry);
}

static void RemoveSteamSemaphoreSocketWaiter(
        MacWSSteamSemaphoreEntry *entry, uint32_t index) {
    if (!entry || index >= entry->waiterSocketCount) return;
    entry->waiterSocketCount--;
    if (index == entry->waiterSocketCount) return;
    size_t remaining = entry->waiterSocketCount - index;
    memmove(&entry->waiterSockets[index],
            &entry->waiterSockets[index + 1],
            remaining * sizeof(entry->waiterSockets[0]));
    memmove(&entry->waiterSocketRequestIDs[index],
            &entry->waiterSocketRequestIDs[index + 1],
            remaining * sizeof(entry->waiterSocketRequestIDs[0]));
    memmove(&entry->waiterSocketIDs[index],
            &entry->waiterSocketIDs[index + 1],
            remaining * sizeof(entry->waiterSocketIDs[0]));
}

static BOOL GrantSteamSemaphoreSocketWaiter(
        MacWSSteamSemaphoreEntry *entry, BOOL diagnostics) {
    while (entry && entry->waiterSocketCount != 0) {
        int descriptor = entry->waiterSockets[0];
        uint64_t requestID = entry->waiterSocketRequestIDs[0];
        uint64_t waiter = entry->waiterSocketIDs[0];
        RemoveSteamSemaphoreSocketWaiter(entry, 0);
        BOOL delivered = WriteSteamSemaphoreWaitReply(
            descriptor, 0, entry->generation, entry->value, requestID);
        close(descriptor);
        if (!delivered) continue;
        if (diagnostics)
            HostLog(@"Steam semaphore EVFILT_READ wake generation=%llu "
                    "waiter=%llu request=%llu remaining=%u",
                    entry->generation, waiter, requestID,
                    entry->waiterSocketCount);
        return YES;
    }
    return NO;
}

static void ExpireSteamSemaphoreSocketWaiter(uint64_t generation,
                                             uint64_t requestID,
                                             BOOL diagnostics) {
    MacWSSteamSemaphoreEntry *entry =
        gSteamSemaphoreGenerations[@(generation)].pointerValue;
    if (!entry) return;
    for (uint32_t index = 0; index < entry->waiterSocketCount; index++) {
        if (entry->waiterSocketRequestIDs[index] != requestID) continue;
        int descriptor = entry->waiterSockets[index];
        uint64_t waiter = entry->waiterSocketIDs[index];
        RemoveSteamSemaphoreSocketWaiter(entry, index);
        MacWSSteamSemaphoreState state = {0};
        int stateError = LockSteamSemaphoreState(entry, &state);
        if (stateError == 0) {
            state.waiterCount = SteamSemaphoreHostWaiterCount(entry);
            stateError = StoreAndUnlockSteamSemaphoreState(entry, &state);
        }
        (void)WriteSteamSemaphoreWaitReply(
            descriptor, stateError ?: EAGAIN, entry->generation,
            entry->value, requestID);
        close(descriptor);
        if (stateError != 0)
            HostLog(@"Steam semaphore timeout state update failed "
                    "generation=%llu request=%llu error=%d",
                    entry->generation, requestID, stateError);
        if (diagnostics)
            HostLog(@"Steam semaphore EVFILT_READ timed out generation=%llu "
                    "waiter=%llu request=%llu remaining=%u",
                    entry->generation, waiter, requestID,
                    entry->waiterSocketCount);
        return;
    }
}

static mach_timebase_info_data_t gSteamSemaphoreTimebase;
static dispatch_once_t gSteamSemaphoreTimebaseOnce;

typedef struct {
    uint64_t generation;
    uint64_t requestID;
    uint64_t deadline;
    BOOL diagnostics;
} MacWSSteamSemaphoreDeadline;

#define MACWS_STEAM_SEM_DEADLINE_CAPACITY 64u
static pthread_mutex_t gSteamSemaphoreDeadlineLock =
    PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gSteamSemaphoreDeadlineCondition =
    PTHREAD_COND_INITIALIZER;
static MacWSSteamSemaphoreDeadline
    gSteamSemaphoreDeadlines[MACWS_STEAM_SEM_DEADLINE_CAPACITY];
static uint32_t gSteamSemaphoreDeadlineHead;
static uint32_t gSteamSemaphoreDeadlineCount;

static uint64_t SteamSemaphoreDeadlineAfterMicroseconds(
        uint32_t microseconds) {
    dispatch_once(&gSteamSemaphoreTimebaseOnce, ^{
        (void)mach_timebase_info(&gSteamSemaphoreTimebase);
    });
    if (gSteamSemaphoreTimebase.numer == 0 ||
        gSteamSemaphoreTimebase.denom == 0) return 0;
    uint64_t nanoseconds = (uint64_t)microseconds * UINT64_C(1000);
    __uint128_t scaled = (__uint128_t)nanoseconds *
        gSteamSemaphoreTimebase.denom + gSteamSemaphoreTimebase.numer - 1;
    uint64_t interval = (uint64_t)(scaled / gSteamSemaphoreTimebase.numer);
    uint64_t now = mach_absolute_time();
    return UINT64_MAX - now < interval ? UINT64_MAX : now + interval;
}

static void *SteamSemaphoreDeadlineThread(void *context) {
    (void)context;
    int qosResult = pthread_set_qos_class_self_np(
        QOS_CLASS_USER_INTERACTIVE, 0);
    // EVFILT_TIMER with NOTE_CRITICAL supplies the measured 10 ms deadline.
    // Do not request THREAD_TIME_CONSTRAINT_POLICY: the deadline thread sleeps
    // between sparse diagnostic requests, and the accepted policy did not
    // improve mach_wait_until wake latency in the on-device probe.
    HostLog(@"Steam semaphore deadline thread qos-result=%d", qosResult);
    int timerQueue = kqueue();
    HostLog(@"Steam semaphore deadline kqueue=%d errno=%d", timerQueue,
            timerQueue >= 0 ? 0 : errno);
    for (;;) {
        pthread_mutex_lock(&gSteamSemaphoreDeadlineLock);
        while (gSteamSemaphoreDeadlineCount == 0)
            pthread_cond_wait(&gSteamSemaphoreDeadlineCondition,
                              &gSteamSemaphoreDeadlineLock);
        MacWSSteamSemaphoreDeadline item =
            gSteamSemaphoreDeadlines[gSteamSemaphoreDeadlineHead];
        gSteamSemaphoreDeadlineHead =
            (gSteamSemaphoreDeadlineHead + 1) %
            MACWS_STEAM_SEM_DEADLINE_CAPACITY;
        gSteamSemaphoreDeadlineCount--;
        pthread_mutex_unlock(&gSteamSemaphoreDeadlineLock);
        int timerResult = -1;
        if (timerQueue >= 0) {
            struct kevent change = {0}, event = {0};
            EV_SET(&change, 1, EVFILT_TIMER,
                   EV_ADD | EV_ENABLE | EV_ONESHOT,
                   NOTE_ABSOLUTE | NOTE_MACHTIME | NOTE_CRITICAL,
                   (intptr_t)item.deadline, NULL);
            do {
                timerResult = kevent(
                    timerQueue, &change, 1, &event, 1, NULL);
            } while (timerResult < 0 && errno == EINTR);
        }
        if (timerResult != 1)
            (void)mach_wait_until(item.deadline);
        if (item.diagnostics) {
            uint64_t woke = mach_absolute_time();
            uint64_t lateTicks = woke > item.deadline ?
                woke - item.deadline : 0;
            double lateMicroseconds = gSteamSemaphoreTimebase.denom ?
                (double)lateTicks * gSteamSemaphoreTimebase.numer /
                    gSteamSemaphoreTimebase.denom / 1000.0 : -1.0;
            HostLog(@"Steam semaphore deadline woke generation=%llu "
                    "request=%llu timer-result=%d late-us=%.3f",
                    item.generation, item.requestID, timerResult,
                    lateMicroseconds);
        }
        dispatch_sync(gSteamSemaphoreQueue, ^{
            ExpireSteamSemaphoreSocketWaiter(
                item.generation, item.requestID, item.diagnostics);
        });
    }
    return NULL;
}

static BOOL StartSteamSemaphoreDeadlineThread(void) {
    pthread_attr_t attributes;
    if (pthread_attr_init(&attributes) != 0) return NO;
    (void)pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    (void)pthread_attr_set_qos_class_np(
        &attributes, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_t thread = NULL;
    int result = pthread_create(
        &thread, &attributes, SteamSemaphoreDeadlineThread, NULL);
    pthread_attr_destroy(&attributes);
    return result == 0;
}

static BOOL ScheduleSteamSemaphoreSocketTimeout(uint64_t generation,
                                                uint64_t requestID,
                                                uint32_t microseconds,
                                                BOOL diagnostics) {
    uint64_t deadline = SteamSemaphoreDeadlineAfterMicroseconds(microseconds);
    if (deadline == 0) return NO;
    // Runtime-confirmed by macws_control_probe on this host service:
    // dispatch_after(10 ms) delivered at 106.530 ms while idle. Use the same
    // absolute Mach deadline primitive on one permanent QoS-bound thread.
    // The thread sleeps without polling and at most 64 exact waiters can be
    // pending, matching the broker's existing bounded waiter storage.
    pthread_mutex_lock(&gSteamSemaphoreDeadlineLock);
    if (gSteamSemaphoreDeadlineCount >=
            MACWS_STEAM_SEM_DEADLINE_CAPACITY) {
        pthread_mutex_unlock(&gSteamSemaphoreDeadlineLock);
        return NO;
    }
    uint32_t tail = (gSteamSemaphoreDeadlineHead +
        gSteamSemaphoreDeadlineCount) % MACWS_STEAM_SEM_DEADLINE_CAPACITY;
    gSteamSemaphoreDeadlines[tail] = (MacWSSteamSemaphoreDeadline){
        .generation = generation,
        .requestID = requestID,
        .deadline = deadline,
        .diagnostics = diagnostics,
    };
    gSteamSemaphoreDeadlineCount++;
    pthread_cond_signal(&gSteamSemaphoreDeadlineCondition);
    pthread_mutex_unlock(&gSteamSemaphoreDeadlineLock);
    return YES;
}

static BOOL SteamSemaphoreDiagnosticsEnabled(xpc_object_t request) {
    return getenv("MACWS_STEAM_SEM_DIAGNOSTICS") != NULL ||
        xpc_dictionary_get_bool(request,
            MACWS_STEAM_SEM_KEY_DIAGNOSTICS);
}

static BOOL ReplySteamSemaphore(xpc_object_t request, int error,
                                uint64_t generation, BOOL created) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    BOOL diagnostics = SteamSemaphoreDiagnosticsEnabled(request);
    if (diagnostics)
        HostLog(@"Steam semaphore reply request=%p peer=%p reply=%p "
                "error=%d generation=%llu", request, peer, reply, error,
                generation);
    if (!peer || !reply) return NO;
    xpc_dictionary_set_int64(reply, MACWS_STEAM_SEM_KEY_ERROR, error);
    if (error == 0 && generation != 0) {
        xpc_dictionary_set_uint64(reply, MACWS_STEAM_SEM_KEY_GENERATION,
                                  generation);
        xpc_dictionary_set_bool(reply, MACWS_STEAM_SEM_KEY_CREATED, created);
    }
    xpc_connection_send_message(peer, reply);
    return YES;
}

static BOOL ReplySteamSemaphoreValue(xpc_object_t request, int error,
                                     uint64_t generation, uint32_t value) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    xpc_object_t reply = xpc_dictionary_create_reply(request);
    BOOL diagnostics = SteamSemaphoreDiagnosticsEnabled(request);
    // EAGAIN is the expected zero-value polling result. Logging every such
    // result changed the system being measured: runtime sampling showed
    // hostd at 92.8% CPU and thousands of lines per second for one generation,
    // while another connection remained on its first reply port. Preserve
    // diagnostics for state transitions and actual errors only.
    if (diagnostics && error != EAGAIN)
        HostLog(@"Steam semaphore value reply request=%p peer=%p reply=%p "
                "error=%d generation=%llu value=%u", request, peer, reply,
                error, generation, value);
    if (!peer || !reply) return NO;
    xpc_dictionary_set_int64(reply, MACWS_STEAM_SEM_KEY_ERROR, error);
    if (error == 0) {
        xpc_dictionary_set_uint64(reply, MACWS_STEAM_SEM_KEY_GENERATION,
                                  generation);
        xpc_dictionary_set_uint64(reply, MACWS_STEAM_SEM_KEY_VALUE, value);
    }
    xpc_connection_send_message(peer, reply);
    return YES;
}

static BOOL ReadSteamSemaphoreWaitRequest(
        int descriptor, MacWSSteamSemaphoreWaitRequest *request) {
    uint8_t *cursor = (uint8_t *)request;
    size_t remaining = sizeof(*request);
    while (remaining != 0) {
        ssize_t amount = read(descriptor, cursor, remaining);
        if (amount < 0 && errno == EINTR) continue;
        if (amount <= 0) return NO;
        cursor += (size_t)amount;
        remaining -= (size_t)amount;
    }
    return YES;
}

static void RemoveSteamSemaphorePollingWaiter(
        MacWSSteamSemaphoreEntry *entry, uint32_t index) {
    if (!entry || index >= entry->pollingWaiterCount) return;
    entry->pollingWaiterCount--;
    if (index == entry->pollingWaiterCount) return;
    memmove(&entry->pollingWaiters[index],
            &entry->pollingWaiters[index + 1],
            (entry->pollingWaiterCount - index) *
                sizeof(entry->pollingWaiters[0]));
    memmove(&entry->pollingWaiterGranted[index],
            &entry->pollingWaiterGranted[index + 1],
            (entry->pollingWaiterCount - index) *
                sizeof(entry->pollingWaiterGranted[0]));
}

static BOOL GrantSteamSemaphorePollingWaiter(
        MacWSSteamSemaphoreEntry *entry, BOOL diagnostics) {
    for (uint32_t index = 0; index < entry->pollingWaiterCount;) {
        if (entry->pollingWaiterGranted[index]) {
            index++;
            continue;
        }
        uint64_t waiter = entry->pollingWaiters[index];
        pid_t waiterPID = (pid_t)(waiter >> 32);
        entry->pollingWaiterGranted[index] = 1;
        if (waiterPID > 1 && kill(waiterPID, SIGUSR2) == 0) {
            if (diagnostics)
                HostLog(@"Steam semaphore FIFO grant generation=%llu "
                        "waiter=%llu pid=%d signal=%d position=%u waiters=%u",
                        entry->generation, waiter, waiterPID, SIGUSR2, index,
                        entry->pollingWaiterCount);
            return YES;
        }
        int signalError = waiterPID <= 1 ? EINVAL : errno;
        if (diagnostics)
            HostLog(@"Steam semaphore FIFO signal failed generation=%llu "
                    "waiter=%llu pid=%d errno=%d",
                    entry->generation, waiter, waiterPID, signalError);
        RemoveSteamSemaphorePollingWaiter(entry, index);
    }
    return NO;
}

static void ServeSteamSemaphoreWaitDescriptor(int descriptor) {
    int enabled = 1;
    (void)setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                     &enabled, sizeof(enabled));
    struct timeval timeout = {.tv_sec = 5, .tv_usec = 0};
    (void)setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO,
                     &timeout, sizeof(timeout));

    pid_t peerPID = 0;
    socklen_t peerPIDSize = sizeof(peerPID);
    int peerResult = getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID,
                                &peerPID, &peerPIDSize);
    if (peerResult != 0 || peerPIDSize != sizeof(peerPID) || peerPID <= 1) {
        int peerError = peerResult == 0 ? EACCES : errno;
        HostLog(@"Steam semaphore socket peer rejected fd=%d result=%d "
                "errno=%d size=%u peer=%d", descriptor, peerResult,
                peerError, peerPIDSize, peerPID);
        (void)WriteSteamSemaphoreWaitReply(
            descriptor, peerError, 0, 0, 0);
        close(descriptor);
        return;
    }

    BOOL handledRequest = NO;
    for (;;) {
        MacWSSteamSemaphoreWaitRequest request = {0};
        BOOL readRequest = ReadSteamSemaphoreWaitRequest(
            descriptor, &request);
        if (!readRequest && handledRequest) {
            // A legacy one-request client closes immediately after its reply;
            // EOF is normal during a rolling hostd/libmachook deployment.
            close(descriptor);
            return;
        }
        BOOL validRequest = readRequest &&
            request.magic == MACWS_STEAM_SEM_WAIT_MAGIC &&
            request.version == MACWS_STEAM_SEM_VERSION &&
            request.generation != 0 && !(request.reserved &
                ~MACWS_STEAM_SEM_SOCKET_FLAG_DIAGNOSTICS) &&
            request.reserved2 == 0 &&
            request.requestID != 0 &&
            (pid_t)(request.waiter >> 32) == peerPID &&
            request.operation >= MACWS_STEAM_SEM_SOCKET_WAIT_POLL &&
            request.operation <= MACWS_STEAM_SEM_SOCKET_WAIT_TIMED &&
            ((request.operation == MACWS_STEAM_SEM_SOCKET_WAIT_TIMED &&
              request.timeoutMicroseconds == 10000) ||
             (request.operation != MACWS_STEAM_SEM_SOCKET_WAIT_TIMED &&
              request.timeoutMicroseconds == 0));
        if (!validRequest) {
            int readError = readRequest ? 0 : errno;
            HostLog(@"Steam semaphore socket request rejected fd=%d read=%d "
                    "errno=%d peer=%d magic=%#x version=%u op=%u flags=%#x "
                    "generation=%llu waiter=%llu waiter_pid=%d request=%llu",
                    descriptor, readRequest, readError, peerPID, request.magic,
                    request.version, request.operation, request.reserved,
                    request.generation, request.waiter,
                    (pid_t)(request.waiter >> 32), request.requestID);
            (void)WriteSteamSemaphoreWaitReply(
                descriptor, EPROTO, request.generation, 0,
                request.requestID);
            close(descriptor);
            return;
        }
        if (!handledRequest) {
            // The first request remains bounded against a peer that connects
            // but sends no envelope. A validated Steam client may retain this
            // channel for its thread lifetime, eliminating one connect,
            // accept, dispatch allocation and close for every 10 ms poll.
            struct timeval persistentTimeout = {0};
            (void)setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO,
                             &persistentTimeout,
                             sizeof(persistentTimeout));
            handledRequest = YES;
        }

        __block BOOL descriptorRetainedByWaiter = NO;
        __block BOOL connectionFailed = NO;
        dispatch_sync(gSteamSemaphoreQueue, ^{
        BOOL diagnostics = (request.reserved &
            MACWS_STEAM_SEM_SOCKET_FLAG_DIAGNOSTICS) != 0;
        if (diagnostics && request.operation !=
                MACWS_STEAM_SEM_SOCKET_GETVALUE)
            HostLog(@"Steam semaphore socket request id=%llu op=%u "
                    "generation=%llu waiter=%llu peer=%d",
                    request.requestID, request.operation,
                    request.generation, request.waiter, peerPID);
        MacWSSteamSemaphoreEntry *entry =
            gSteamSemaphoreGenerations[@(request.generation)].pointerValue;
        if (!entry || entry->references == 0) {
            if (!WriteSteamSemaphoreWaitReply(
                    descriptor, EINVAL, request.generation, 0,
                    request.requestID))
                connectionFailed = YES;
            return;
        }
        int replyError = 0;
        uint32_t replyValue = entry->value;
        MacWSSteamSemaphoreState state = {0};
        int stateError = LockSteamSemaphoreState(entry, &state);
        BOOL stateDirty = NO;
        if (stateError != 0) {
            replyError = stateError;
        } else if (request.operation ==
                       MACWS_STEAM_SEM_SOCKET_WAIT_BLOCK ||
                   request.operation ==
                       MACWS_STEAM_SEM_SOCKET_WAIT_TIMED) {
            if (state.value != 0) {
                state.value--;
                stateDirty = YES;
            } else if (entry->waiterSocketCount >=
                       sizeof(entry->waiterSockets) /
                           sizeof(entry->waiterSockets[0])) {
                replyError = ENOSPC;
            } else {
                uint32_t index = entry->waiterSocketCount++;
                entry->waiterSockets[index] = descriptor;
                entry->waiterSocketRequestIDs[index] = request.requestID;
                entry->waiterSocketIDs[index] = request.waiter;
                state.waiterCount = SteamSemaphoreHostWaiterCount(entry);
                stateDirty = YES;
                descriptorRetainedByWaiter = YES;
                if (diagnostics)
                    HostLog(@"Steam semaphore EVFILT_READ enqueue "
                            "generation=%llu waiter=%llu request=%llu "
                            "position=%u waiters=%u",
                            entry->generation, request.waiter,
                            request.requestID, index,
                            entry->waiterSocketCount);
            }
        } else if (request.operation ==
                   MACWS_STEAM_SEM_SOCKET_WAIT_POLL) {
            if (request.waiter == 0) {
                replyError = EINVAL;
            } else {
                uint32_t index = 0;
                for (; index < entry->pollingWaiterCount; index++) {
                    if (entry->pollingWaiters[index] == request.waiter) break;
                }
                if (index == entry->pollingWaiterCount) {
                    if (index >= sizeof(entry->pollingWaiters) /
                                     sizeof(entry->pollingWaiters[0])) {
                        replyError = ENOSPC;
                    } else {
                        entry->pollingWaiters[index] = request.waiter;
                        entry->pollingWaiterGranted[index] = 0;
                        entry->pollingWaiterCount++;
                        if (state.value != 0) {
                            state.value--;
                            entry->pollingWaiterGranted[index] = 1;
                        }
                        state.waiterCount =
                            SteamSemaphoreHostWaiterCount(entry);
                        stateDirty = YES;
                        if (diagnostics)
                            HostLog(@"Steam semaphore socket FIFO enqueue "
                                    "generation=%llu waiter=%llu granted=%u "
                                    "position=%u waiters=%u",
                                    entry->generation, request.waiter,
                                    entry->pollingWaiterGranted[index], index,
                                    entry->pollingWaiterCount);
                    }
                }
                if (replyError == 0)
                    replyValue = entry->pollingWaiterGranted[index] ? 1 : 0;
            }
        } else if (request.operation ==
                   MACWS_STEAM_SEM_SOCKET_TRYWAIT) {
            BOOL consumedGrant = NO;
            if (request.waiter != 0) {
                for (uint32_t index = 0;
                     index < entry->pollingWaiterCount; index++) {
                    if (entry->pollingWaiters[index] != request.waiter ||
                        !entry->pollingWaiterGranted[index]) continue;
                    RemoveSteamSemaphorePollingWaiter(entry, index);
                    state.waiterCount =
                        SteamSemaphoreHostWaiterCount(entry);
                    consumedGrant = YES;
                    stateDirty = YES;
                    break;
                }
            }
            if (!consumedGrant) {
                if (state.value == 0) replyError = EAGAIN;
                else {
                    state.value--;
                    stateDirty = YES;
                }
            }
        } else if (request.operation == MACWS_STEAM_SEM_SOCKET_POST) {
            if (GrantSteamSemaphoreSocketWaiter(entry, diagnostics) ||
                GrantSteamSemaphorePollingWaiter(entry, diagnostics)) {
                state.waiterCount = SteamSemaphoreHostWaiterCount(entry);
                stateDirty = YES;
            } else if (state.value == MACWS_STEAM_SEM_VALUE_MAX) {
                replyError = EOVERFLOW;
            } else {
                state.value++;
                stateDirty = YES;
            }
        }

        if (stateError == 0) {
            replyValue = state.value;
            int storeError = stateDirty ?
                StoreAndUnlockSteamSemaphoreState(entry, &state) : 0;
            if (!stateDirty) UnlockSteamSemaphoreState(entry);
            if (storeError != 0) {
                replyError = storeError;
                if (descriptorRetainedByWaiter) {
                    for (uint32_t index = 0;
                         index < entry->waiterSocketCount; index++) {
                        if (entry->waiterSocketRequestIDs[index] !=
                                request.requestID) continue;
                        RemoveSteamSemaphoreSocketWaiter(entry, index);
                        break;
                    }
                    descriptorRetainedByWaiter = NO;
                }
            }
        }

        if (descriptorRetainedByWaiter) {
            if (request.operation == MACWS_STEAM_SEM_SOCKET_WAIT_TIMED &&
                !ScheduleSteamSemaphoreSocketTimeout(
                    request.generation, request.requestID,
                    request.timeoutMicroseconds, diagnostics)) {
                ExpireSteamSemaphoreSocketWaiter(
                    request.generation, request.requestID, diagnostics);
            }
            return;
        }

        if (diagnostics && request.operation !=
                MACWS_STEAM_SEM_SOCKET_GETVALUE &&
            (replyError != EAGAIN || replyValue != 0))
            HostLog(@"Steam semaphore socket reply id=%llu op=%u "
                    "generation=%llu waiter=%llu error=%d value=%u",
                    request.requestID, request.operation,
                    request.generation, request.waiter, replyError,
                    replyValue);
        if (!WriteSteamSemaphoreWaitReply(
                descriptor, replyError, entry->generation, replyValue,
                request.requestID))
            connectionFailed = YES;
        });
        if (descriptorRetainedByWaiter) return;
        if (connectionFailed) {
            close(descriptor);
            return;
        }
    }
}

static BOOL StartSteamSemaphoreWaitListener(void) {
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)] = {0};
    int length = snprintf(path, sizeof(path), "%s%s", kRootFS,
                          MACWS_STEAM_SEM_WAIT_SOCKET_PATH);
    if (length <= 0 || (size_t)length >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return NO;
    }
    (void)unlink(path);
    int descriptor = socket(AF_UNIX, SOCK_STREAM, 0);
    if (descriptor < 0) return NO;
    int enabled = 1;
    (void)setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE,
                     &enabled, sizeof(enabled));

    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    struct passwd *mobileAccount = getpwnam("mobile");
    uid_t clientUID = mobileAccount ? mobileAccount->pw_uid : 501;
    gid_t clientGID = mobileAccount ? mobileAccount->pw_gid : 501;
    if (bind(descriptor, (const struct sockaddr *)&address,
             sizeof(address)) != 0 ||
        chown(path, clientUID, clientGID) != 0 ||
        chmod(path, 0600) != 0 || listen(descriptor, 64) != 0) {
        int savedError = errno;
        close(descriptor);
        (void)unlink(path);
        errno = savedError;
        return NO;
    }
    int flags = fcntl(descriptor, F_GETFL, 0);
    if (flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != 0) {
        int savedError = errno;
        close(descriptor);
        (void)unlink(path);
        errno = savedError;
        return NO;
    }

    gSteamSemaphoreWaitListenerDescriptor = descriptor;
    dispatch_queue_t listenerQueue = dispatch_queue_create(
        "com.macwsguide.hostd.steam-semaphore-wait-listener",
        DISPATCH_QUEUE_SERIAL);
    gSteamSemaphoreWaitListener = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)descriptor, 0, listenerQueue);
    dispatch_source_set_event_handler(gSteamSemaphoreWaitListener, ^{
        for (;;) {
            int client = accept(descriptor, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR) continue;
                if (errno != EAGAIN && errno != EWOULDBLOCK)
                    HostLog(@"Steam semaphore wait accept failed errno=%d",
                            errno);
                break;
            }
            // Runtime-confirmed on the real iPad: accepted descriptors inherit
            // O_NONBLOCK from this listener.  Before the client's first bytes
            // arrived, ReadSteamSemaphoreWaitRequest returned EAGAIN and the
            // server emitted an empty EPROTO envelope; Steam then reported
            // `Locked the ceiling, couldn't release the floor` for /MTX/.
            // Requests are fixed-size and SO_RCVTIMEO bounds a stalled peer,
            // so restore blocking mode on the connected descriptor before
            // reading the request.
            int clientFlags = fcntl(client, F_GETFL, 0);
            if (clientFlags < 0 ||
                fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) != 0) {
                int savedError = errno ?: EIO;
                HostLog(@"Steam semaphore accepted socket mode failed "
                        "fd=%d errno=%d", client, savedError);
                close(client);
                continue;
            }
            // A validated client keeps one channel per calling thread. Do not
            // block the serial accept queue while that channel waits for its
            // next request. Counter mutation and reply ordering remain
            // serialized by gSteamSemaphoreQueue inside the worker.
            dispatch_async(dispatch_get_global_queue(
                QOS_CLASS_USER_INITIATED, 0), ^{
                    ServeSteamSemaphoreWaitDescriptor(client);
                });
        }
    });
    dispatch_source_set_cancel_handler(gSteamSemaphoreWaitListener, ^{
        close(descriptor);
    });
    dispatch_resume(gSteamSemaphoreWaitListener);
    HostLog(@"Steam semaphore wait listener published path=%s protocol=%u",
            path, MACWS_STEAM_SEM_VERSION);
    return YES;
}

static void ServeSteamSemaphoreRequest(xpc_object_t request,
                                       const char *operation) {
    // Keep this protocol independent of the GUI control queue. Steam's WebUI
    // handshakes can wait while another application launch is in progress;
    // applying the hostd "busy" gate here would deadlock an unrelated client.
    BOOL resetOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_RESET);
    BOOL openOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_OPEN);
    BOOL recreateOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_RECREATE);
    BOOL unlinkOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_UNLINK);
    BOOL delayOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_DELAY);
    BOOL tryWaitOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_TRYWAIT);
    BOOL waitPollOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_WAIT_POLL);
    BOOL postOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_POST);
    BOOL getValueOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_GETVALUE);
    BOOL registerWaitOperation =
        !strcmp(operation, MACWS_STEAM_SEM_OP_REGISTER_WAIT);
    BOOL notifyOperation = !strcmp(operation, MACWS_STEAM_SEM_OP_NOTIFY);

    if (delayOperation) {
        uint64_t microseconds = xpc_dictionary_get_uint64(
            request, MACWS_STEAM_SEM_KEY_VALUE);
        // Runtime LLDB on the real Steam Helper showed that
        // macOS-originated nanosleep, kevent timers and thread_switch waits
        // never expire on this iOS kernel. A first host-side implementation
        // called usleep, but that blocked the broker itself in
        // __semwait_signal. Let iOS-native libdispatch own the deadline.
        //
        // This operation deliberately bypasses gSteamSemaphoreQueue. CEF can
        // issue a deadline while steam_osx is publishing a large batch of
        // logical names; deadline delivery must not depend on draining that
        // unrelated namespace traffic first.
        if (microseconds == 0 || microseconds > 100000) {
            ReplySteamSemaphore(request, EINVAL, 0, NO);
            return;
        }
        dispatch_after(dispatch_time(
            DISPATCH_TIME_NOW,
            (int64_t)(microseconds * NSEC_PER_USEC)),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                ReplySteamSemaphore(request, 0, 0, NO);
            });
        return;
    }

    dispatch_async(gSteamSemaphoreQueue, ^{
        if (resetOperation) {
            const char *epoch = xpc_dictionary_get_string(
                request, MACWS_STEAM_SEM_KEY_EPOCH);
            if (!epoch || epoch[0] == '\0' || strnlen(epoch, 128) >= 128) {
                ReplySteamSemaphore(request, EINVAL, 0, NO);
                return;
            }
            NSString *requestedEpoch = @(epoch);
            if ([gSteamSemaphoreEpoch isEqualToString:requestedEpoch]) {
                ReplySteamSemaphore(request, 0, 0, NO);
                return;
            }
            NSArray<NSValue *> *entries =
                gSteamSemaphoreGenerations.allValues.copy;
            [gSteamSemaphoreNames removeAllObjects];
            [gSteamSemaphoreGenerations removeAllObjects];
            [gSteamSemaphoreUnlinkReceipts removeAllObjects];
            for (NSValue *value in entries) {
                MacWSSteamSemaphoreEntry *entry = value.pointerValue;
                UnlinkSteamSemaphoreState(entry);
                DestroySteamSemaphoreEntry(entry);
            }
            gSteamSemaphoreEpoch = requestedEpoch;
            HostLog(@"Steam semaphore namespace reset epoch=%@ count=%lu",
                    requestedEpoch, (unsigned long)entries.count);
            ReplySteamSemaphore(request, 0, 0, NO);
            return;
        }

        const char *name = xpc_dictionary_get_string(
            request, MACWS_STEAM_SEM_KEY_NAME);
        if (openOperation || recreateOperation) {
            if (!IsSteamSemaphoreName(name)) {
                ReplySteamSemaphore(request, EINVAL, 0, NO);
                return;
            }
            BOOL created = NO;
            int flags = (int)xpc_dictionary_get_int64(
                request, MACWS_STEAM_SEM_KEY_FLAGS);
            uint64_t initialValue = xpc_dictionary_get_uint64(
                request, MACWS_STEAM_SEM_KEY_VALUE);
            NSString *key = @(name);
            MacWSSteamSemaphoreEntry *entry =
                gSteamSemaphoreNames[key].pointerValue;
            if (recreateOperation) {
                uint64_t receipt = xpc_dictionary_get_uint64(
                    request, MACWS_STEAM_SEM_KEY_GENERATION);
                NSNumber *expected = gSteamSemaphoreUnlinkReceipts[key];
                if (!(flags & O_CREAT) || !(flags & O_EXCL) || receipt == 0 ||
                    !expected || expected.unsignedLongLongValue != receipt) {
                    ReplySteamSemaphore(request, ESTALE, 0, NO);
                    return;
                }
                [gSteamSemaphoreUnlinkReceipts removeObjectForKey:key];
                uint64_t replacedGeneration = 0;
                if (entry) {
                    replacedGeneration = entry->generation;
                    [gSteamSemaphoreNames removeObjectForKey:key];
                    entry->unlinked = YES;
                    UnlinkSteamSemaphoreState(entry);
                    if (entry->references == 0) {
                        [gSteamSemaphoreGenerations
                            removeObjectForKey:@(entry->generation)];
                        DestroySteamSemaphoreEntry(entry);
                    }
                    entry = NULL;
                }
                if (SteamSemaphoreDiagnosticsEnabled(request))
                    HostLog(@"Steam semaphore atomic recreate name=%s "
                            "receipt=%llu replaced-generation=%llu",
                            name, receipt, replacedGeneration);
            }
            if (entry && (flags & O_CREAT) && (flags & O_EXCL)) {
                if (SteamSemaphoreDiagnosticsEnabled(request))
                    HostLog(@"Steam semaphore open EEXIST name=%s "
                            "flags=%#x initial=%llu generation=%llu "
                            "references=%u unlinked=%d",
                            name, flags, initialValue, entry->generation,
                            entry->references, entry->unlinked);
                ReplySteamSemaphore(request, EEXIST, 0, NO);
                return;
            }
            if (!entry && !(flags & O_CREAT)) {
                if (SteamSemaphoreDiagnosticsEnabled(request))
                    HostLog(@"Steam semaphore open ENOENT name=%s "
                            "flags=%#x initial=%llu",
                            name, flags, initialValue);
                ReplySteamSemaphore(request, ENOENT, 0, NO);
                return;
            }
            if (!entry) {
                if (initialValue > INT32_MAX) {
                    ReplySteamSemaphore(request, EINVAL, 0, NO);
                    return;
                }
                entry = calloc(1, sizeof(*entry));
                if (!entry) {
                    ReplySteamSemaphore(request, ENOMEM, 0, NO);
                    return;
                }
                entry->stateDescriptor = -1;
                entry->generation = ++gSteamSemaphoreNextGeneration;
                entry->value = (uint32_t)initialValue;
                strlcpy(entry->name, name, sizeof(entry->name));
                int createError = CreateSteamSemaphoreState(
                    entry, (uint32_t)initialValue);
                if (createError != 0) {
                    DestroySteamSemaphoreEntry(entry);
                    ReplySteamSemaphore(request, createError, 0, NO);
                    return;
                }
                NSValue *value = [NSValue valueWithPointer:entry];
                gSteamSemaphoreNames[key] = value;
                gSteamSemaphoreGenerations[@(entry->generation)] = value;
                created = YES;
            }
            if (entry->references == UINT32_MAX) {
                ReplySteamSemaphore(request, EMFILE, 0, NO);
                return;
            }
            entry->references++;
            ReplySteamSemaphore(request, 0, entry->generation, created);
            return;
        }

        if (unlinkOperation) {
            if (!IsSteamSemaphoreName(name)) {
                ReplySteamSemaphore(request, EINVAL, 0, NO);
                return;
            }
            NSString *key = @(name);
            MacWSSteamSemaphoreEntry *entry =
                gSteamSemaphoreNames[key].pointerValue;
            if (!entry) {
                ReplySteamSemaphore(request, ENOENT, 0, NO);
                return;
            }
            [gSteamSemaphoreNames removeObjectForKey:key];
            entry->unlinked = YES;
            uint64_t generation = entry->generation;
            gSteamSemaphoreUnlinkReceipts[key] = @(generation);
            UnlinkSteamSemaphoreState(entry);
            if (entry->references == 0) {
                [gSteamSemaphoreGenerations
                    removeObjectForKey:@(entry->generation)];
                DestroySteamSemaphoreEntry(entry);
            }
            ReplySteamSemaphore(request, 0, generation, NO);
            return;
        }

        uint64_t generation = xpc_dictionary_get_uint64(
            request, MACWS_STEAM_SEM_KEY_GENERATION);
        MacWSSteamSemaphoreEntry *entry =
            gSteamSemaphoreGenerations[@(generation)].pointerValue;
        if (!entry || entry->references == 0) {
            ReplySteamSemaphore(request, EINVAL, 0, NO);
            return;
        }

        uint64_t waiter = xpc_dictionary_get_uint64(
            request, MACWS_STEAM_SEM_KEY_WAITER);

        // Legacy XPC high-frequency adapter retained only for protocol
        // diagnostics. Protocol v23 clients mutate the authoritative state
        // vnode directly for uncontended value operations and use the stream
        // listener only for real waiters. Keep these diagnostic operations on
        // that same locked state transaction: entry->value is a reply/log
        // mirror, never an independent counter.
        if (tryWaitOperation) {
            MacWSSteamSemaphoreState state = {0};
            int stateError = LockSteamSemaphoreState(entry, &state);
            if (stateError != 0) {
                ReplySteamSemaphoreValue(
                    request, stateError, generation, entry->value);
                return;
            }
            if (waiter != 0) {
                for (uint32_t index = 0;
                     index < entry->pollingWaiterCount; index++) {
                    if (entry->pollingWaiters[index] != waiter ||
                        !entry->pollingWaiterGranted[index]) continue;
                    RemoveSteamSemaphorePollingWaiter(entry, index);
                    state.waiterCount =
                        SteamSemaphoreHostWaiterCount(entry);
                    stateError = StoreAndUnlockSteamSemaphoreState(
                        entry, &state);
                    ReplySteamSemaphoreValue(
                        request, stateError, generation, state.value);
                    return;
                }
            }
            if (state.value == 0) {
                // A synchronous client cannot enqueue its next poll until it
                // receives this reply. Yield once before replying so the XPC
                // listener can enqueue work from another Steam process or
                // generation; this is a fairness boundary, not a fabricated
                // timeout or semaphore token.
                UnlockSteamSemaphoreState(entry);
                sched_yield();
                ReplySteamSemaphoreValue(request, EAGAIN, generation, 0);
                return;
            }
            state.value--;
            stateError = StoreAndUnlockSteamSemaphoreState(entry, &state);
            ReplySteamSemaphoreValue(
                request, stateError, generation, state.value);
            return;
        }

        if (postOperation) {
            MacWSSteamSemaphoreState state = {0};
            int stateError = LockSteamSemaphoreState(entry, &state);
            if (stateError != 0) {
                ReplySteamSemaphoreValue(
                    request, stateError, generation, entry->value);
                return;
            }
            BOOL diagnostics = SteamSemaphoreDiagnosticsEnabled(request);
            if (GrantSteamSemaphoreSocketWaiter(entry, diagnostics) ||
                GrantSteamSemaphorePollingWaiter(entry, diagnostics)) {
                state.waiterCount = SteamSemaphoreHostWaiterCount(entry);
                stateError = StoreAndUnlockSteamSemaphoreState(entry, &state);
                ReplySteamSemaphoreValue(
                    request, stateError, generation, state.value);
                return;
            }
            if (state.value == MACWS_STEAM_SEM_VALUE_MAX) {
                UnlockSteamSemaphoreState(entry);
                ReplySteamSemaphoreValue(request, EOVERFLOW, generation,
                                         state.value);
                return;
            }
            state.value++;
            stateError = StoreAndUnlockSteamSemaphoreState(entry, &state);
            ReplySteamSemaphoreValue(
                request, stateError, generation, state.value);
            return;
        }

        if (getValueOperation) {
            MacWSSteamSemaphoreState state = {0};
            int stateError = LockSteamSemaphoreState(entry, &state);
            if (stateError == 0) UnlockSteamSemaphoreState(entry);
            ReplySteamSemaphoreValue(
                request, stateError, generation,
                stateError == 0 ? state.value : entry->value);
            return;
        }

        if (waitPollOperation) {
            if (waiter == 0) {
                ReplySteamSemaphoreValue(request, EINVAL, generation, 0);
                return;
            }
            MacWSSteamSemaphoreState state = {0};
            int stateError = LockSteamSemaphoreState(entry, &state);
            if (stateError != 0) {
                ReplySteamSemaphoreValue(
                    request, stateError, generation, entry->value);
                return;
            }
            for (uint32_t index = 0;
                 index < entry->pollingWaiterCount; index++) {
                if (entry->pollingWaiters[index] != waiter) continue;
                UnlockSteamSemaphoreState(entry);
                ReplySteamSemaphoreValue(
                    request, 0, generation,
                    entry->pollingWaiterGranted[index] ? 1 : 0);
                return;
            }
            if (entry->pollingWaiterCount >=
                sizeof(entry->pollingWaiters) /
                    sizeof(entry->pollingWaiters[0])) {
                UnlockSteamSemaphoreState(entry);
                ReplySteamSemaphoreValue(request, ENOSPC, generation, 0);
                return;
            }
            uint32_t index = entry->pollingWaiterCount++;
            entry->pollingWaiters[index] = waiter;
            if (state.value != 0) {
                state.value--;
                entry->pollingWaiterGranted[index] = 1;
            }
            state.waiterCount = SteamSemaphoreHostWaiterCount(entry);
            stateError = StoreAndUnlockSteamSemaphoreState(entry, &state);
            if (SteamSemaphoreDiagnosticsEnabled(request))
                HostLog(@"Steam semaphore FIFO enqueue generation=%llu "
                        "waiter=%llu granted=%u position=%u waiters=%u",
                        generation, waiter,
                        entry->pollingWaiterGranted[index], index,
                        entry->pollingWaiterCount);
            ReplySteamSemaphoreValue(
                request, stateError, generation,
                entry->pollingWaiterGranted[index] ? 1 : 0);
            return;
        }

        if (registerWaitOperation) {
            mach_port_t port = xpc_dictionary_copy_mach_send(
                request, MACWS_STEAM_SEM_KEY_WAIT_PORT);
            if (!MACH_PORT_VALID(port)) {
                ReplySteamSemaphore(request, EINVAL, 0, NO);
                return;
            }
            BOOL duplicate = NO;
            for (uint32_t index = 0; index < entry->waiterCount; index++) {
                if (entry->waiterPorts[index] == port) {
                    duplicate = YES;
                    break;
                }
            }
            if (duplicate) {
                (void)mach_port_deallocate(mach_task_self(), port);
            } else if (entry->waiterCount >=
                       sizeof(entry->waiterPorts) /
                           sizeof(entry->waiterPorts[0])) {
                (void)mach_port_deallocate(mach_task_self(), port);
                ReplySteamSemaphore(request, ENOSPC, 0, NO);
                return;
            } else {
                entry->waiterPorts[entry->waiterCount++] = port;
            }
            if (SteamSemaphoreDiagnosticsEnabled(request))
                HostLog(@"Steam semaphore registered wake port "
                        "generation=%llu port=%u waiters=%u",
                        generation, port, entry->waiterCount);
            ReplySteamSemaphore(request, 0, generation, NO);
            return;
        }

        if (notifyOperation) {
            mach_msg_header_t message = {0};
            message.msgh_bits = MACH_MSGH_BITS(
                MACH_MSG_TYPE_COPY_SEND, 0);
            message.msgh_size = sizeof(message);
            message.msgh_id = 0x4d5753;
            uint32_t output = 0;
            for (uint32_t index = 0; index < entry->waiterCount; index++) {
                mach_port_t port = entry->waiterPorts[index];
                message.msgh_remote_port = port;
                mach_msg_return_t sendResult = mach_msg(
                    &message, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                    sizeof(message), 0, MACH_PORT_NULL, 0,
                    MACH_PORT_NULL);
                if (sendResult == MACH_SEND_INVALID_DEST) {
                    // The failed mach_msg has already disposed the invalid
                    // destination name.  Deallocating that numeric name a
                    // second time is not a harmless KERN_INVALID_NAME on this
                    // iOS kernel: the task has a Mach-port guard and is killed
                    // with EXC_GUARD/INVALID_NAME.  Runtime witness from the
                    // production Steam bootstrap (2026-08-14):
                    //
                    //   macwshostd[98055] SIGKILL
                    //   GUARD_TYPE_MACH_PORT INVALID_NAME on mach port 35075
                    //
                    // Removing the dead destination from the waiter table is
                    // the complete ownership transition after this send
                    // result; there is no remaining right to release.
                    continue;
                }
                entry->waiterPorts[output++] = port;
            }
            entry->waiterCount = output;
            if (SteamSemaphoreDiagnosticsEnabled(request))
                HostLog(@"Steam semaphore notify generation=%llu "
                        "waiters=%u", generation, output);
            return;
        }

        entry->references--;
        if (entry->unlinked && entry->references == 0) {
            [gSteamSemaphoreGenerations removeObjectForKey:@(generation)];
            DestroySteamSemaphoreEntry(entry);
        }
        ReplySteamSemaphore(request, 0, 0, NO);
    });
}

// UE4's Metal backend streams complete legacy MTLB archives rather than MSL.
// Ventura accepts the container at newLibraryWithData:, but iOS AGX later
// rejects a pipeline whose AIR module still targets macOS.  Translate that
// target at the library boundary in this iOS-native helper, where the device's
// real LLVM tools are available, and persist a byte-exact cache entry.  This
// is deliberately a typed Stray-only operation: no caller supplies a path or
// argv, and a failed structural conversion is returned as a real failure.
enum {
    MacWSMetalLibraryHeaderSize = 88,
    MacWSMetalLibraryMaximumSize = 1024 * 1024,
};

static uint16_t MetalReadU16(const uint8_t *bytes, size_t offset) {
    uint16_t value = 0;
    memcpy(&value, bytes + offset, sizeof(value));
    return value;
}

static uint32_t MetalReadU32(const uint8_t *bytes, size_t offset) {
    uint32_t value = 0;
    memcpy(&value, bytes + offset, sizeof(value));
    return value;
}

static uint64_t MetalReadU64(const uint8_t *bytes, size_t offset) {
    uint64_t value = 0;
    memcpy(&value, bytes + offset, sizeof(value));
    return value;
}

static uint64_t MetalFNV1a64(const uint8_t *bytes, size_t length) {
    uint64_t value = UINT64_C(1469598103934665603);
    for (size_t index = 0; index < length; index++) {
        value ^= bytes[index];
        value *= UINT64_C(1099511628211);
    }
    return value;
}

static BOOL ValidateMetalLibraryData(NSData *data, BOOL source,
                                     uint64_t *hashOut,
                                     NSString **message) {
    const uint8_t *bytes = data.bytes;
    size_t length = data.length;
    if (!bytes || length < MacWSMetalLibraryHeaderSize ||
        length > MacWSMetalLibraryMaximumSize ||
        memcmp(bytes, "MTLB", 4) != 0 ||
        MetalReadU64(bytes, 16) != length) {
        if (message) *message = @"MTLB 头或容器长度无效";
        return NO;
    }
    uint16_t platform = MetalReadU16(bytes, 4);
    uint8_t targetOS = bytes[11];
    if (source) {
        // Metal 902.1 legacy archives encode targetOS=0 and carry the
        // authoritative macOS triple inside each AIR module.  Newer macOS
        // archives use the explicit 0x81 value.  An iOS/macabi archive must
        // never enter this conversion path.
        if (platform != 0x8001 || (targetOS != 0x00 && targetOS != 0x81)) {
            if (message) *message = @"输入不是受支持的 macOS MTLB";
            return NO;
        }
    } else if (platform != 0x8001 || targetOS != 0x86) {
        if (message) *message = @"转换结果没有声明 macabi 目标";
        return NO;
    }
    static const size_t sectionOffsets[] = {24, 40, 56, 72};
    for (size_t index = 0;
         index < sizeof(sectionOffsets) / sizeof(sectionOffsets[0]); index++) {
        size_t field = sectionOffsets[index];
        uint64_t offset = MetalReadU64(bytes, field);
        uint64_t size = MetalReadU64(bytes, field + 8);
        if (offset > length || size > length - offset ||
            ((index == 0 || index == 3) &&
             (offset < MacWSMetalLibraryHeaderSize || size == 0))) {
            if (message) *message = [NSString stringWithFormat:
                @"MTLB section %zu 越界", index];
            return NO;
        }
    }
    uint64_t functionOffset = MetalReadU64(bytes, 24);
    if (functionOffset > length - sizeof(uint32_t)) {
        if (message) *message = @"MTLB function table 越界";
        return NO;
    }
    uint32_t functionCount = MetalReadU32(bytes, (size_t)functionOffset);
    if (functionCount == 0 || functionCount > 65536) {
        if (message) *message = @"MTLB function count 无效";
        return NO;
    }
    if (hashOut) *hashOut = MetalFNV1a64(bytes, length);
    return YES;
}

static BOOL EnsureMetalCompatDirectory(NSString **message) {
    struct stat status = {0};
    if (lstat(kMetalCompatWorkingDirectory, &status) != 0) {
        if (errno != ENOENT ||
            mkdir(kMetalCompatWorkingDirectory, 0700) != 0) {
            if (message) *message = [NSString stringWithFormat:
                @"无法创建 Metal 转换目录（errno=%d）", errno];
            return NO;
        }
    } else if (!S_ISDIR(status.st_mode) || S_ISLNK(status.st_mode)) {
        if (message) *message = @"Metal 转换目录类型无效";
        return NO;
    }
    if (chown(kMetalCompatWorkingDirectory, 0, 0) != 0 ||
        chmod(kMetalCompatWorkingDirectory, 0700) != 0) {
        if (message) *message = [NSString stringWithFormat:
            @"无法保护 Metal 转换目录（errno=%d）", errno];
        return NO;
    }
    return YES;
}

static BOOL WriteMetalDataAtomically(NSData *data, NSString *path,
                                     NSString **message) {
    NSString *template = [path stringByAppendingString:@".XXXXXX"];
    char temporary[PATH_MAX] = {0};
    if (![template getFileSystemRepresentation:temporary
                                      maxLength:sizeof(temporary)]) {
        if (message) *message = @"Metal 临时路径过长";
        return NO;
    }
    int descriptor = mkstemp(temporary);
    if (descriptor < 0) {
        if (message) *message = [NSString stringWithFormat:
            @"无法创建 Metal 临时文件（errno=%d）", errno];
        return NO;
    }
    BOOL ok = fchmod(descriptor, 0600) == 0;
    int savedErrno = ok ? 0 : errno;
    const uint8_t *bytes = data.bytes;
    size_t written = 0;
    while (ok && written < data.length) {
        ssize_t count = write(descriptor, bytes + written,
                              data.length - written);
        if (count > 0) {
            written += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            ok = NO;
            savedErrno = count < 0 ? errno : EIO;
        }
    }
    if (ok && fsync(descriptor) != 0) {
        ok = NO;
        savedErrno = errno;
    }
    if (close(descriptor) != 0 && ok) {
        ok = NO;
        savedErrno = errno;
    }
    if (ok && rename(temporary, path.fileSystemRepresentation) != 0) {
        ok = NO;
        savedErrno = errno;
    }
    if (!ok) {
        (void)unlink(temporary);
        if (message) *message = [NSString stringWithFormat:
            @"写入 Metal 转换输入失败（errno=%d）", savedErrno];
    }
    return ok;
}

// The game waits synchronously at -newLibraryWithData:error:, so a wedged
// converter must have a real upper bound.  Put the fixed converter argv in a
// fresh process group, poll the real child status, and terminate that whole
// group on timeout.  Returning 124 keeps Metal's original failure semantics;
// no library or pipeline success is fabricated.
static int RunMetalCompatCommand(const char *const argv[],
                                 NSTimeInterval timeout) {
    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions);
    if (error != 0) return 128 + error;
    int logFD = open(kMetalCompatLog,
                     O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (logFD >= 0) {
        (void)posix_spawn_file_actions_adddup2(
            &actions, logFD, STDOUT_FILENO);
        (void)posix_spawn_file_actions_adddup2(
            &actions, logFD, STDERR_FILENO);
        (void)posix_spawn_file_actions_addclose(&actions, logFD);
    }
    posix_spawnattr_t attributes;
    error = posix_spawnattr_init(&attributes);
    BOOL attributesInitialized = error == 0;
    if (error == 0)
        error = posix_spawnattr_setflags(&attributes,
                                         POSIX_SPAWN_SETPGROUP);
    if (error == 0)
        error = posix_spawnattr_setpgroup(&attributes, 0);
    pid_t pid = 0;
    if (error == 0) {
        error = posix_spawn(&pid, argv[0], &actions, &attributes,
                            (char *const *)argv, environ);
    }
    if (attributesInitialized) posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (logFD >= 0) close(logFD);
    if (error != 0) {
        HostLog(@"metal-retarget spawn failed executable=%s error=%d (%s)",
                argv[0], error, strerror(error));
        return 128 + error;
    }

    HostLog(@"metal-retarget spawned pid=%d executable=%s timeout=%.1fs",
            pid, argv[0], timeout);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    int status = 0;
    for (;;) {
        pid_t waited = waitpid(pid, &status, WNOHANG);
        if (waited == pid) break;
        if (waited < 0 && errno != EINTR) return 127;
        if (deadline.timeIntervalSinceNow <= 0) {
            HostLog(@"metal-retarget timeout pid=%d executable=%s",
                    pid, argv[0]);
            (void)kill(-pid, SIGTERM);
            NSDate *termDeadline =
                [NSDate dateWithTimeIntervalSinceNow:0.5];
            do {
                waited = waitpid(pid, &status, WNOHANG);
                if (waited == pid) return 124;
                usleep(20000);
            } while (termDeadline.timeIntervalSinceNow > 0);
            (void)kill(-pid, SIGKILL);
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            return 124;
        }
        usleep(20000);
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 126;
}

static pid_t MetalCompatPeerPID(xpc_object_t request) {
    xpc_connection_t peer = xpc_dictionary_get_remote_connection(request);
    if (!peer) return 0;
    typedef pid_t (*ConnectionGetPID)(xpc_connection_t);
    static ConnectionGetPID getPID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getPID = (ConnectionGetPID)dlsym(
            RTLD_DEFAULT, "xpc_connection_get_pid");
    });
    return getPID ? getPID(peer) : 0;
}

// Notes 16.3 returns a real callback-scoped NSURL, but the Host's direct
// open(2) receives EPERM even while the URL exists.  Runtime-confirmed via
// /var/mobile/Library/Logs/MacWSHost.log at 1789057282.681 and
// 1789057285.296.  Keep the privilege boundary at the upstream file-open:
// only the exact native MacWSHost executable may request a copy, the source
// must be a regular file below an iOS data/group container, and the new file
// must be created below the fixed MacWS Imports root with O_NOFOLLOW|O_EXCL.
// This preserves the provider's bytes and filename; it does not fabricate a
// successful representation when the real source cannot be opened.
static BOOL MacWSProviderSourcePathAllowed(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0 ||
        ![path isAbsolutePath]) return NO;
    NSString *standard = path.stringByStandardizingPath;
    for (NSString *root in @[@"/private/var/mobile/Containers",
                              @"/var/mobile/Containers"]) {
        if ([standard hasPrefix:[root stringByAppendingString:@"/"]])
            return YES;
    }
    return NO;
}

static BOOL MacWSProviderDestinationPathAllowed(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0 ||
        ![path isAbsolutePath]) return NO;
    NSString *standard = path.stringByStandardizingPath;
    NSString *root = [@(kProviderImportRoot).stringByStandardizingPath
        stringByAppendingString:@"/"];
    return [standard hasPrefix:root];
}

static BOOL CopyProviderFileForHost(NSString *sourcePath,
                                    NSString *destinationPath,
                                    uint64_t *copiedBytes,
                                    NSString **message) {
    if (!MacWSProviderSourcePathAllowed(sourcePath) ||
        !MacWSProviderDestinationPathAllowed(destinationPath)) {
        if (message) *message = @"提供器暂存路径不在允许范围内";
        return NO;
    }

    char resolvedSource[PATH_MAX] = {0};
    if (!realpath(sourcePath.fileSystemRepresentation, resolvedSource)) {
        if (message) *message = [NSString stringWithFormat:
            @"无法验证提供器源文件（errno=%d）", errno];
        return NO;
    }
    NSString *resolvedSourcePath = [NSString stringWithUTF8String:
        resolvedSource];
    if (!MacWSProviderSourcePathAllowed(resolvedSourcePath)) {
        if (message) *message = @"提供器源文件越过 iOS 容器目录";
        return NO;
    }

    NSString *parentPath = destinationPath.stringByDeletingLastPathComponent;
    char resolvedParent[PATH_MAX] = {0};
    char resolvedRoot[PATH_MAX] = {0};
    if (!realpath(parentPath.fileSystemRepresentation, resolvedParent) ||
        !realpath(kProviderImportRoot, resolvedRoot)) {
        if (message) *message = @"无法验证提供器暂存目录";
        return NO;
    }
    size_t rootLength = strlen(resolvedRoot);
    if (strncmp(resolvedParent, resolvedRoot, rootLength) != 0 ||
        resolvedParent[rootLength] != '/') {
        if (message) *message = @"提供器暂存目录越过固定导入根目录";
        return NO;
    }

    int sourceFD = open(resolvedSource,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (sourceFD < 0) {
        if (message) *message = [NSString stringWithFormat:
            @"无法读取提供器文件（errno=%d）", errno];
        return NO;
    }
    struct stat sourceStat = {0};
    if (fstat(sourceFD, &sourceStat) != 0 ||
        !S_ISREG(sourceStat.st_mode) || sourceStat.st_size < 0) {
        int savedErrno = errno ?: EINVAL;
        close(sourceFD);
        if (message) *message = [NSString stringWithFormat:
            @"提供器文件类型或大小不受支持（errno=%d）", savedErrno];
        return NO;
    }

    int destinationFD = open(destinationPath.fileSystemRepresentation,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (destinationFD < 0) {
        int savedErrno = errno;
        close(sourceFD);
        if (message) *message = [NSString stringWithFormat:
            @"无法创建提供器暂存文件（errno=%d）", savedErrno];
        return NO;
    }

    uint64_t total = 0;
    BOOL copied = MacWSCopyStableRegularFile(sourceFD, destinationFD, &total) == 0;
    int savedErrno = copied ? 0 : errno;
    if (close(destinationFD) != 0 && copied) {
        copied = NO;
        savedErrno = errno;
    }
    close(sourceFD);
    if (!copied) {
        unlink(destinationPath.fileSystemRepresentation);
        if (message) *message = [NSString stringWithFormat:
            @"复制提供器文件失败（errno=%d）", savedErrno ?: EIO];
        return NO;
    }
    if (copiedBytes) *copiedBytes = total;
    if (message) *message = @"提供器文件已暂存";
    return YES;
}

static void ServeProviderFileRequest(xpc_object_t request) {
    pid_t peerPID = MetalCompatPeerPID(request);
    NSString *peerPath = RootExecutablePathForPID(peerPID);
    if (peerPID <= 1 || ![peerPath isEqualToString:@(kMacWSHostExecutable)]) {
        ReplyResult(request, NO, @"调用者不是 MacWSHost", nil);
        HostLog(@"provider-stage rejected peer=%d path=%@", peerPID,
                peerPath ?: @"(unknown)");
        return;
    }
    const char *source = xpc_dictionary_get_string(
        request, MACWS_CONTROL_KEY_PROVIDER_SOURCE_PATH);
    const char *destination = xpc_dictionary_get_string(
        request, MACWS_CONTROL_KEY_PROVIDER_DESTINATION_PATH);
    NSString *sourcePath = source ? [NSString stringWithUTF8String:source] : nil;
    NSString *destinationPath = destination
        ? [NSString stringWithUTF8String:destination] : nil;
    uint64_t copiedBytes = 0;
    NSString *message = nil;
    BOOL copied = CopyProviderFileForHost(
        sourcePath, destinationPath, &copiedBytes, &message);
    HostLog(@"provider-stage peer=%d source=%@ destination=%@ bytes=%llu result=%@ message=%@",
            peerPID, sourcePath ?: @"(nil)",
            destinationPath ?: @"(nil)",
            (unsigned long long)copiedBytes,
            copied ? @"ok" : @"failed", message ?: @"");
    ReplyResult(request, copied, message, ^(xpc_object_t reply) {
        xpc_dictionary_set_uint64(reply, "copied_bytes", copiedBytes);
    });
}

static NSData *LoadCachedMetalReplacement(size_t sourceLength,
                                          uint64_t sourceHash,
                                          uint64_t *replacementHashOut,
                                          NSString **message) {
    NSString *stem = [NSString stringWithFormat:@"%zu-%016llx",
                      sourceLength, (unsigned long long)sourceHash];
    NSString *libraryPath = [@(kMetalCompatExactDirectory)
        stringByAppendingPathComponent:[stem stringByAppendingString:
            @".metallib"]];
    NSString *metadataPath = [@(kMetalCompatExactDirectory)
        stringByAppendingPathComponent:[stem stringByAppendingString:@".meta"]];
    struct stat libraryStatus = {0}, metadataStatus = {0};
    if (stat(libraryPath.fileSystemRepresentation, &libraryStatus) != 0 ||
        stat(metadataPath.fileSystemRepresentation, &metadataStatus) != 0 ||
        libraryStatus.st_uid != 0 || metadataStatus.st_uid != 0 ||
        !S_ISREG(libraryStatus.st_mode) || !S_ISREG(metadataStatus.st_mode) ||
        (libraryStatus.st_mode & (S_IWGRP | S_IWOTH)) != 0 ||
        (metadataStatus.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return nil;
    }
    NSString *metadata = ReadSmallTextFile(
        metadataPath.fileSystemRepresentation, 128);
    unsigned long long expectedHash = 0;
    unsigned long long expectedLength = 0;
    char trailing = 0;
    if (sscanf(metadata.UTF8String ?: "", "%llu %llx %c",
               &expectedLength, &expectedHash, &trailing) != 2 ||
        expectedLength < MacWSMetalLibraryHeaderSize ||
        expectedLength > MacWSMetalLibraryMaximumSize ||
        libraryStatus.st_size != (off_t)expectedLength) {
        if (message) *message = @"Metal 精确缓存 metadata 无效";
        return nil;
    }
    NSData *replacement = [NSData dataWithContentsOfFile:libraryPath];
    uint64_t observedHash = 0;
    NSString *validationMessage = nil;
    if (!ValidateMetalLibraryData(replacement, NO, &observedHash,
                                  &validationMessage) ||
        observedHash != (uint64_t)expectedHash) {
        if (message) *message = validationMessage ?:
            @"Metal 精确缓存哈希不匹配";
        return nil;
    }
    if (replacementHashOut) *replacementHashOut = observedHash;
    return replacement;
}

static NSData *ConvertAndCacheMetalLibrary(NSData *source,
                                           uint64_t sourceHash,
                                           uint64_t *replacementHashOut,
                                           BOOL *cacheHitOut,
                                           NSString **message) {
    NSData *cached = LoadCachedMetalReplacement(
        source.length, sourceHash, replacementHashOut, nil);
    if (cached) {
        if (cacheHitOut) *cacheHitOut = YES;
        return cached;
    }
    if (cacheHitOut) *cacheHitOut = NO;
    if (!EnsureMetalCompatDirectory(message)) return nil;
    const char *required[] = {
        kProcursusPython, kMetalCompatConverter, kMetalCompatInstaller,
        kLLVM16Dis, kLLVM16As,
    };
    for (size_t index = 0;
         index < sizeof(required) / sizeof(required[0]); index++) {
        if (access(required[index], index == 0 || index >= 3 ? X_OK : R_OK)
                != 0) {
            if (message) *message = [NSString stringWithFormat:
                @"Metal 转换依赖缺失：%s", required[index]];
            return nil;
        }
    }

    NSString *sourceName = [NSString stringWithFormat:
        @"macws_mtl_data_0000_%016llx.bin",
        (unsigned long long)sourceHash];
    NSString *sourcePath = [@(kMetalCompatWorkingDirectory)
        stringByAppendingPathComponent:sourceName];
    NSString *outputPath = [@(kMetalCompatWorkingDirectory)
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"%zu-%016llx.converted.metallib", source.length,
            (unsigned long long)sourceHash]];
    (void)unlink(outputPath.fileSystemRepresentation);
    if (!WriteMetalDataAtomically(source, sourcePath, message)) return nil;

    const char *convert[] = {
        kProcursusPython, kMetalCompatConverter,
        sourcePath.fileSystemRepresentation,
        outputPath.fileSystemRepresentation,
        "--llvm-dis", kLLVM16Dis,
        "--llvm-as", kLLVM16As,
        "--target-triple", "air64-apple-ios19.0.0-macabi",
        "--container-target", "macabi",
        "--target-major", "19",
        "--target-minor", "0",
        // Apply only lowerings whose complete, registered AIR/LLVM call shape
        // is present.  Runtime A/B for Stray's scene-transition pipeline
        // proved that target retargeting alone leaves a fixed 24-byte memset
        // which iOS 16 AGX rejects, while the equivalent three i64 stores
        // build with the unchanged descriptor.  Unknown shapes still fail
        // closed in the converter.
        "--auto-lower-known-air",
        NULL,
    };
    int conversionResult = RunMetalCompatCommand(convert, 20.0);
    if (conversionResult != 0) {
        if (message) *message = [NSString stringWithFormat:
            @"MTLB 转换失败（退出码 %d）", conversionResult];
        (void)unlink(sourcePath.fileSystemRepresentation);
        (void)unlink(outputPath.fileSystemRepresentation);
        return nil;
    }
    const char *install[] = {
        kProcursusPython, kMetalCompatInstaller,
        sourcePath.fileSystemRepresentation,
        "--prebuilt-replacement", outputPath.fileSystemRepresentation,
        NULL,
    };
    int installResult = RunMetalCompatCommand(install, 10.0);
    (void)unlink(sourcePath.fileSystemRepresentation);
    (void)unlink(outputPath.fileSystemRepresentation);
    if (installResult != 0) {
        if (message) *message = [NSString stringWithFormat:
            @"MTLB 精确缓存安装失败（退出码 %d）", installResult];
        return nil;
    }
    NSData *replacement = LoadCachedMetalReplacement(
        source.length, sourceHash, replacementHashOut, message);
    if (!replacement && message && !*message)
        *message = @"MTLB 转换完成但精确缓存验证失败";
    return replacement;
}

static void ServeMetalLibraryRetargetRequest(xpc_object_t request) {
    pid_t peerPID = MetalCompatPeerPID(request);
    NSString *peerPath = RootExecutablePathForPID(peerPID);
    struct stat probeStatus = {0};
    BOOL productionPeer =
        [peerPath isEqualToString:@(kStrayExecutable)];
    BOOL diagnosticPeer =
        [peerPath isEqualToString:@(kMetalCompatProbeExecutable)] &&
        stat(kMetalCompatProbeExecutable, &probeStatus) == 0 &&
        S_ISREG(probeStatus.st_mode) && probeStatus.st_uid == 0 &&
        (probeStatus.st_mode & (S_IWGRP | S_IWOTH)) == 0;
    if (peerPID <= 1 || (!productionPeer && !diagnosticPeer)) {
        ReplyResult(request, NO, @"调用者不是受支持的 Stray 进程", nil);
        HostLog(@"metal-retarget rejected peer=%d path=%@", peerPID,
                peerPath ?: @"(unknown)");
        return;
    }
    size_t sourceLength = 0;
    const void *sourceBytes = xpc_dictionary_get_data(
        request, MACWS_CONTROL_KEY_METAL_LIBRARY, &sourceLength);
    NSData *source = sourceBytes && sourceLength
        ? [NSData dataWithBytes:sourceBytes length:sourceLength] : nil;
    uint64_t sourceHash = 0;
    NSString *message = nil;
    if (!ValidateMetalLibraryData(source, YES, &sourceHash, &message)) {
        ReplyResult(request, NO, message ?: @"MTLB 输入无效", nil);
        return;
    }
    uint64_t claimedLength = xpc_dictionary_get_uint64(
        request, MACWS_CONTROL_KEY_SOURCE_LENGTH);
    uint64_t claimedHash = xpc_dictionary_get_uint64(
        request, MACWS_CONTROL_KEY_SOURCE_HASH);
    if (claimedLength != sourceLength || claimedHash != sourceHash) {
        ReplyResult(request, NO, @"MTLB 请求身份与字节不匹配", nil);
        return;
    }
    CFAbsoluteTime began = CFAbsoluteTimeGetCurrent();
    uint64_t replacementHash = 0;
    BOOL cacheHit = NO;
    NSData *replacement = ConvertAndCacheMetalLibrary(
        source, sourceHash, &replacementHash, &cacheHit, &message);
    double elapsedMS = (CFAbsoluteTimeGetCurrent() - began) * 1000.0;
    BOOL ok = replacement != nil;
    HostLog(@"metal-retarget peer=%d kind=%@ source=%zu/%016llx result=%@ "
            "replacement=%lu/%016llx cache=%@ elapsed-ms=%.3f message=%@",
            peerPID, productionPeer ? @"stray" : @"diagnostic",
            sourceLength, (unsigned long long)sourceHash,
            ok ? @"ok" : @"failed", (unsigned long)replacement.length,
            (unsigned long long)replacementHash,
            cacheHit ? @"hit" : @"converted", elapsedMS, message ?: @"");
    ReplyResult(request, ok, ok ? @"MTLB 已转换为 macabi" : message,
                ^(xpc_object_t reply) {
        xpc_dictionary_set_uint64(reply, MACWS_CONTROL_KEY_SOURCE_LENGTH,
                                  sourceLength);
        xpc_dictionary_set_uint64(reply, MACWS_CONTROL_KEY_SOURCE_HASH,
                                  sourceHash);
        xpc_dictionary_set_bool(reply, "cache_hit", cacheHit);
        xpc_dictionary_set_double(reply, "elapsed_ms", elapsedMS);
        if (!replacement) return;
        xpc_dictionary_set_uint64(
            reply, MACWS_CONTROL_KEY_REPLACEMENT_LENGTH,
            replacement.length);
        xpc_dictionary_set_uint64(
            reply, MACWS_CONTROL_KEY_REPLACEMENT_HASH, replacementHash);
        xpc_dictionary_set_data(reply, MACWS_CONTROL_KEY_METAL_LIBRARY,
                                replacement.bytes, replacement.length);
    });
}

static void ServeRequest(xpc_object_t request) {
    if (xpc_get_type(request) != XPC_TYPE_DICTIONARY) return;
    const char *op = xpc_dictionary_get_string(request, MACWS_CONTROL_KEY_OP);
    if (!op) {
        ReplyResult(request, NO, @"缺少操作类型", nil);
        return;
    }
    if (IsSteamSemaphoreOperation(op)) {
        ServeSteamSemaphoreRequest(request, op);
        return;
    }
    if (IsSteamMachRendezvousOperation(op)) {
        ServeSteamMachRendezvousRequest(request, op);
        return;
    }
    if (strcmp(op, MACWS_CONTROL_OP_STATUS) == 0) {
        ReplyResult(request, YES, @"状态已刷新", ^(xpc_object_t reply) { AddStatus(reply); });
        return;
    }
    if (strcmp(op, MACWS_CONTROL_OP_LOGS) == 0) {
        ReplyResult(request, YES, @"日志已刷新", ^(xpc_object_t reply) {
            SetString(reply, "hostd_log", TailFile(kLogPath, 32768));
            SetString(reply, "windowserver_log", TailFile("/var/jb/var/mobile/WindowServer.err", 32768));
            SetString(reply, "input_log", TailFile("/var/jb/var/mobile/macwsinputd.err", 16384));
            SetString(reply, "postinst_log", TailFile("/var/jb/var/mobile/postinst.log", 16384));
        });
        return;
    }
    if (strcmp(op, MACWS_CONTROL_OP_RESOLVE_HOST) == 0) {
        ReplyHostResolution(request);
        return;
    }
    if (strcmp(op, MACWS_CONTROL_OP_RETARGET_METAL_LIBRARY) == 0) {
        dispatch_async(gMetalCompatQueue, ^{
            @autoreleasepool {
                ServeMetalLibraryRetargetRequest(request);
            }
        });
        return;
    }
    if (strcmp(op, MACWS_CONTROL_OP_STAGE_PROVIDER_FILE) == 0) {
        dispatch_async(gProviderFileQueue, ^{
            @autoreleasepool {
                ServeProviderFileRequest(request);
            }
        });
        return;
    }

    dispatch_async(gControlQueue, ^{
        os_unfair_lock_lock(&gStateLock);
        BOOL alreadyBusy = gBusy;
        if (!alreadyBusy) gBusy = YES;
        os_unfair_lock_unlock(&gStateLock);
        if (alreadyBusy) {
            ReplyResult(request, NO, @"另一项系统操作正在执行", ^(xpc_object_t reply) { AddStatus(reply); });
            return;
        }

        NSString *message = @"不支持的操作";
        BOOL ok = NO;
        pid_t launchedAppPID = 0;
        if (strcmp(op, MACWS_CONTROL_OP_START) == 0) {
            os_unfair_lock_lock(&gStateLock);
            gStartupOperationActive = YES;
            gStartupRetryAvailable = NO;
            gStartupBeganAt = time(NULL);
            os_unfair_lock_unlock(&gStateLock);
            BOOL experimental = xpc_dictionary_get_bool(request, MACWS_CONTROL_KEY_EXPERIMENTAL);
            ok = StartGUI(experimental, &message);
            os_unfair_lock_lock(&gStateLock);
            gStartupOperationActive = NO;
            gStartupRetryAvailable = !ok;
            os_unfair_lock_unlock(&gStateLock);
        } else if (strcmp(op, MACWS_CONTROL_OP_STOP) == 0) {
            SetState(YES, @"停止 macOS GUI…", @"");
            ok = StopGUI(&message);
        } else if (strcmp(op, MACWS_CONTROL_OP_REPAIR) == 0) {
            SetState(YES, @"停止工作区并修复启动环境…", @"");
            if (JobHasPID(kWindowServerLabel, NULL)) {
                NSString *stopMessage = nil;
                if (!StopGUI(&stopMessage)) {
                    message = [NSString stringWithFormat:@"修复前无法安全停止工作区：%@",
                               stopMessage ?: @"未知错误"];
                    SetState(NO, @"操作失败", message);
                    ReplyResult(request, NO, message,
                                ^(xpc_object_t reply) { AddStatus(reply); });
                    return;
                }
            }
            SetState(YES, @"重新签名并恢复信任缓存…", @"");
            const char *argv[] = {kBash, kPostinst, NULL};
            int rc = access(kPostinst, R_OK) == 0 ? RunCommand(argv, YES) : 127;
            ok = rc == 0;
            message = ok ? @"启动环境修复完成" :
                [NSString stringWithFormat:@"环境修复失败（退出码 %d）", rc];
        } else if (strcmp(op, MACWS_CONTROL_OP_REPAIR_DESKTOP) == 0) {
            // This is intentionally distinct from the full environment
            // repair above.  The script keeps WindowServer and ordinary app
            // PIDs alive, then rebuilds only the login-session services that
            // own icons, Dock/Spaces, wallpaper and the menu extras.
            SetState(YES, @"保留应用并修复桌面服务…", @"");
            BOOL windowServerWasRunning =
                JobHasPID(kWindowServerLabel, NULL);
            int rc = 0;
            BOOL escalated = NO;
            BOOL minimalRebuild = NO;
            if (!windowServerWasRunning) {
                // Runtime-confirmed via MacWSDesktopRepair.log:174-177 on
                // 2026-08-23: after an escalated rebuild stopped the damaged
                // generation but its replacement failed preflight, every
                // later Repair Desktop request called the in-place script
                // again.  That script correctly returned "requires a running
                // WindowServer", but hostd treated the typed offline state as
                // a terminal rc=1 and left the button unable to recover the
                // workspace.  A stopped desktop has no application PIDs to
                // preserve, so enter the same production StartGUI transaction
                // used by the primary button and require all of its service
                // endpoint witnesses before reporting success.
                SetState(YES, @"桌面会话离线，正在完整恢复…", @"");
                NSString *startMessage = nil;
                ok = StartGUI(NO, &startMessage);
                message = ok
                    ? @"macOS 桌面会话已重新启动；Dock、桌布、菜单服务与最终合成已恢复"
                    : [NSString stringWithFormat:
                        @"桌面会话离线且恢复失败：%@",
                        startMessage ?: @"启动失败"];
            } else {
                const char *argv[] = {kBash, kGUI, "repair-desktop", NULL};
                rc = RunCommandToLog(argv, YES, kDesktopRepairLogPath);
                escalated = rc == 2;
                if (escalated) {
                    // The in-place path proved its service PIDs but did not
                    // get a fresh WindowServer-owned final-composite witness.
                    // Keeping that generation alive would knowingly return
                    // the Host to a window-layer fallback that cannot
                    // reproduce Dock/menu materials. Escalate only on this
                    // typed result; ordinary script failures never trigger a
                    // broader teardown.
                    SetState(YES, @"最终合成无响应，正在快速切换显示会话…", @"");
                    const char *rebuildArgv[] = {
                        kBash, kGUI, "rebuild-desktop-session",
                        "--no-terminal", "--no-vnc", NULL,
                    };
                    int rebuildRC = RunCommandToLog(
                        rebuildArgv, YES, kDesktopRepairLogPath);
                    minimalRebuild = rebuildRC == 0;
                    if (minimalRebuild) {
                        ok = YES;
                        message = @"最终合成曾失去响应；已快速切换 WindowServer 显示会话并验证 Dock、毛玻璃和输入";
                    } else {
                        // The bounded session-only path changes neither the
                        // persistent LaunchServices catalog nor trust state.
                        // Fall back to the full production transaction only
                        // when its real pixel/input postconditions fail.
                        SetState(YES, @"快速切换失败，正在完整恢复桌面…", @"");
                        NSString *stopMessage = nil;
                        NSString *startMessage = nil;
                        BOOL stopped = StopGUI(&stopMessage);
                        BOOL started = stopped && StartGUI(NO,
                                                           &startMessage);
                        ok = stopped && started;
                        message = ok
                            ? @"快速切换未通过验证；已完成全量桌面恢复"
                            : [NSString stringWithFormat:
                                @"桌面最终合成恢复失败：%@",
                                stopped ? (startMessage ?: @"启动失败")
                                        : (stopMessage ?: @"停止失败")];
                    }
                } else {
                    ok = rc == 0;
                    message = ok
                        ? @"Dock、图标、桌布、菜单服务与最终合成已验证；当前应用已保留"
                        : [NSString stringWithFormat:
                            @"桌面修复失败（退出码 %d），请查看诊断日志", rc];
                }
            }
            HostLog(@"desktop-repair result=%@ rc=%d recovery=%s log=%s",
                    ok ? (!windowServerWasRunning ? @"started-offline" :
                          (escalated ? (minimalRebuild ? @"rebuilt-session" : @"rebuilt-full") : @"ready")) : @"failed",
                    rc,
                    escalated ? (minimalRebuild ? "session" : "full") : "in-place",
                    kDesktopRepairLogPath);
        } else if (strcmp(op, MACWS_CONTROL_OP_RECOVER) == 0) {
            SetState(YES, @"执行安全恢复…", @"");
            ok = StopGUI(&message);
        } else if (strcmp(op, MACWS_CONTROL_OP_LAUNCH_APP) == 0) {
            SetState(YES, @"启动 macOS 应用…", @"");
            ok = LaunchAllowedApp(xpc_dictionary_get_string(request, MACWS_CONTROL_KEY_APP_ID), &message);
            if (ok) {
                os_unfair_lock_lock(&gStateLock);
                launchedAppPID = gActiveAppPID;
                os_unfair_lock_unlock(&gStateLock);
            }
        } else if (strcmp(op, MACWS_CONTROL_OP_OPEN_DOCUMENTS) == 0) {
            SetState(YES, @"正在打开 macOS 文稿…", @"");
            ok = OpenDocumentsRequest(request, &launchedAppPID, &message);
        } else if (strcmp(op, MACWS_CONTROL_OP_OPEN_WEB_URL) == 0) {
            SetState(YES, @"正在用 VS Code 打开网页…", @"");
            ok = OpenWebURLRequest(request, &launchedAppPID, &message);
        } else if (strcmp(op, MACWS_CONTROL_OP_LAUNCH_PATH) == 0) {
            SetState(YES, @"启动 macOS 路径…", @"");
            ok = LaunchRequestedPath(
                xpc_dictionary_get_string(request, MACWS_CONTROL_KEY_APP_PATH),
                xpc_dictionary_get_bool(
                    request, MACWS_CONTROL_KEY_DOCUMENT_OPEN_PENDING),
                &message);
            if (ok) {
                os_unfair_lock_lock(&gStateLock);
                launchedAppPID = gActiveAppPID;
                os_unfair_lock_unlock(&gStateLock);
            }
        } else if (strcmp(op, MACWS_CONTROL_OP_CAPTURE) == 0) {
            SetState(YES, @"请求刷新共享帧…", @"");
            int wsPID = 0;
            uint64_t generation = 0;
            ok = JobHasPID(kWindowServerLabel, &wsPID) &&
                 (generation = ArmCapture()) != 0 &&
                 WaitForCapture(wsPID, generation, 60.0, NULL);
            message = ok ? @"共享帧已刷新并由 WindowServer 确认" :
                @"WindowServer 未在 60 秒内确认刷新帧";
        } else if (strcmp(op, MACWS_CONTROL_OP_REFRESH_DOCK) == 0) {
            // Retained for protocol compatibility with older Host builds. It
            // now only verifies that the target exited; a normal app close is
            // never authority to terminate the healthy Dock process.
            pid_t targetPID = (pid_t)xpc_dictionary_get_int64(
                request, MACWS_CONTROL_KEY_TARGET_PID);
            ok = RefreshDockAfterProcessExit(targetPID, &message);
        }

        SetState(NO, ok ? @"就绪" : @"操作失败", ok ? @"" : message);
        ReplyResult(request, ok, message, ^(xpc_object_t reply) {
            AddStatus(reply);
            if (launchedAppPID > 1)
                xpc_dictionary_set_int64(reply, "launched_app_pid",
                                         launchedAppPID);
        });
    });
}

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        // launchd provides a deliberately sparse environment.  macos_gui.sh
        // uses standard Procursus tools (id, ps, grep, awk, ...), so define
        // the same explicit iOS-side PATH used by the documented SSH flow.
        setenv("PATH", "/var/jb/usr/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
        setenv("HOME", "/var/jb/var/root", 1);
        setenv("TMPDIR", "/tmp", 1);
        gControlQueue = dispatch_queue_create("com.macwsguide.hostd.control", DISPATCH_QUEUE_SERIAL);
        gLogQueue = dispatch_queue_create("com.macwsguide.hostd.log", DISPATCH_QUEUE_SERIAL);
        gSteamSemaphoreQueue = dispatch_queue_create(
            "com.macwsguide.hostd.steam-semaphore", DISPATCH_QUEUE_SERIAL);
        if (!StartSteamSemaphoreDeadlineThread())
            HostLog(@"Steam semaphore deadline thread failed to start");
        gSteamMachRendezvousQueue = dispatch_queue_create(
            "com.macwsguide.hostd.steam-mach-rendezvous",
            DISPATCH_QUEUE_SERIAL);
        gMetalCompatQueue = dispatch_queue_create(
            "com.macwsguide.hostd.metal-compat", DISPATCH_QUEUE_SERIAL);
        gProviderFileQueue = dispatch_queue_create(
            "com.macwsguide.hostd.provider-file", DISPATCH_QUEUE_SERIAL);
        gSteamSemaphoreNames = [NSMutableDictionary dictionary];
        gSteamMachRendezvousPorts = [NSMutableDictionary dictionary];
        gSteamSemaphoreGenerations = [NSMutableDictionary dictionary];
        gSteamSemaphoreUnlinkReceipts = [NSMutableDictionary dictionary];
        gApplicationSessions = [NSMutableDictionary dictionary];
        gSteamSemaphoreNextGeneration =
            ((uint64_t)arc4random() << 32) | arc4random();
        if (gSteamSemaphoreNextGeneration == UINT64_MAX)
            gSteamSemaphoreNextGeneration = 1;
        if (!StartSteamSemaphoreWaitListener()) {
            HostLog(@"failed to publish Steam semaphore wait listener "
                    "errno=%d", errno);
            return 1;
        }
        HostLog(@"macwshostd starting pid=%d protocol=%u uid=%d", getpid(),
                MACWS_CONTROL_VERSION, getuid());
        StartApplicationSessionSupervisor();
        StartWorkspacePowerCoordinator();

        xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
            dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (!createMach) {
            HostLog(@"xpc_connection_create_mach_service symbol missing");
            return 1;
        }
        dispatch_queue_t listenerQueue = dispatch_queue_create(
            "com.macwsguide.hostd.listener", DISPATCH_QUEUE_SERIAL);
        xpc_connection_t listener = createMach(
            MACWS_CONTROL_SERVICE, listenerQueue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (!listener) {
            HostLog(@"failed to create mach listener");
            return 1;
        }
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
            xpc_connection_set_event_handler((xpc_connection_t)peer, ^(xpc_object_t event) {
                ServeRequest(event);
            });
            xpc_connection_resume((xpc_connection_t)peer);
        });
        xpc_connection_resume(listener);
        HostLog(@"published %s", MACWS_CONTROL_SERVICE);
        dispatch_main();
    }
    return 0;
}
