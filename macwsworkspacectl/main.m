#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <dlfcn.h>
#import <errno.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <ptrauth.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>
#import <sys/wait.h>
#import <sys/socket.h>
#import <sys/un.h>

#import "../include/macws_host_protocol.h"

extern char **environ;

typedef CFTypeRef (*MacWSLSSharedFileListCreateFn)(
    CFAllocatorRef, CFStringRef, CFTypeRef);
typedef CFArrayRef (*MacWSLSSharedFileListCopySnapshotFn)(CFTypeRef, UInt32 *);
typedef CFStringRef (*MacWSLSSharedFileListItemCopyDisplayNameFn)(CFTypeRef);
typedef CFURLRef (*MacWSLSSharedFileListItemCopyResolvedURLFn)(
    CFTypeRef, UInt32, CFErrorRef *);

static int ConfigureAirPlayPowerDefaults(void) {
    typedef int32_t (*APSSettingsSetUseXPCHelperFn)(bool);
    typedef int64_t (*APSSettingsGetInt64Fn)(CFStringRef, int32_t *);
    typedef int32_t (*APSSettingsSetInt64Fn)(CFStringRef, int64_t);
    static const char *const framework =
        "/System/Library/PrivateFrameworks/"
        "AirPlaySupport.framework/AirPlaySupport";
    void *image = dlopen(framework, RTLD_NOW | RTLD_LOCAL);
    APSSettingsSetUseXPCHelperFn setUseXPCHelper = image
        ? (APSSettingsSetUseXPCHelperFn)dlsym(
              image, "APSSettingsSetUseXPCHelper") : NULL;
    APSSettingsGetInt64Fn getSetting = image
        ? (APSSettingsGetInt64Fn)dlsym(image, "APSSettingsGetInt64") : NULL;
    APSSettingsSetInt64Fn setSetting = image
        ? (APSSettingsSetInt64Fn)dlsym(image, "APSSettingsSetInt64") : NULL;
    if (!setUseXPCHelper || !getSetting || !setSetting) {
        fprintf(stderr,
                "macwsworkspacectl: AirPlay settings SPI unavailable "
                "(image=%s route=%s get=%s set=%s)\n",
                image ? "yes" : "no", setUseXPCHelper ? "yes" : "no",
                getSetting ? "yes" : "no",
                setSetting ? "yes" : "no");
        if (image) dlclose(image);
        return 69;
    }

    // RE-confirmed in the iPad13,6 Ventura/iPadOS-16.3 runtime:
    // -[APAdvertiserBTLEManager updateSupportsSoloAndForceReadFromPrefs:]
    // reads this public AirPlay setting first. When absent it asks IO80211 for
    // AWDL Solo support; that unsupported query returns an error and leaves
    // the manager's initialized byte clear, so its timer retries forever.
    // Persisting the supported preference path lets Apple's own method finish
    // initialization and cancel its timer. The chroot cannot provide AWDL, so
    // false is the truthful capability value rather than a check bypass.
    // RE-confirmed via the actual AirPlaySupport image: the supported
    // APSSettingsSetUseXPCHelper(false) entry point selects the same
    // com.apple.airplay CFPreferences backend used by showInMenuBar keys.
    // The outer iPadOS launchd cannot host Ventura's incompatible helper, so
    // choose this Apple-provided backend before the first settings read.
    int32_t routeStatus = setUseXPCHelper(false);
    if (routeStatus != 0) {
        fprintf(stderr,
                "macwsworkspacectl: AirPlay preferences route failed: %d\n",
                routeStatus);
        dlclose(image);
        return 1;
    }
    CFStringRef key = CFSTR("p2pSolo");
    int32_t readStatus = 0;
    int64_t oldValue = getSetting(key, &readStatus);
    int32_t setStatus = 0;
    if (readStatus != 0 || oldValue != 0)
        setStatus = setSetting(key, 0);
    int32_t verifyStatus = 0;
    int64_t value = getSetting(key, &verifyStatus);
    if (setStatus != 0 || verifyStatus != 0 || value != 0) {
        fprintf(stderr,
                "macwsworkspacectl: AirPlay p2pSolo configuration failed "
                "route=%d read=%d old=%lld set=%d verify=%d value=%lld\n",
                routeStatus, readStatus, (long long)oldValue, setStatus,
                verifyStatus, (long long)value);
        dlclose(image);
        return 1;
    }
    fprintf(stdout,
            "airplay-power-ready key=p2pSolo value=0 previous=%lld "
            "route-status=%d read-status=%d\n",
            (long long)oldValue, routeStatus, readStatus);
    dlclose(image);
    return 0;
}

static int SharedFileListReady(void) {
    MacWSLSSharedFileListCreateFn createList =
        (MacWSLSSharedFileListCreateFn)dlsym(
            RTLD_DEFAULT, "LSSharedFileListCreate");
    MacWSLSSharedFileListCopySnapshotFn copySnapshot =
        (MacWSLSSharedFileListCopySnapshotFn)dlsym(
            RTLD_DEFAULT, "LSSharedFileListCopySnapshot");
    CFStringRef *recentDocuments = (CFStringRef *)dlsym(
        RTLD_DEFAULT, "kLSSharedFileListRecentDocumentItems");
    if (!createList || !copySnapshot || !recentDocuments ||
        !*recentDocuments) {
        fprintf(stderr,
                "macwsworkspacectl: SharedFileList SPI unavailable "
                "(create=%s snapshot=%s list=%s)\n",
                createList ? "yes" : "no",
                copySnapshot ? "yes" : "no",
                recentDocuments && *recentDocuments ? "yes" : "no");
        return 69;
    }

    CFTypeRef list = createList(kCFAllocatorDefault, *recentDocuments, NULL);
    if (!list) {
        fprintf(stderr,
                "macwsworkspacectl: recent-document list creation failed\n");
        return 1;
    }
    UInt32 seed = 0;
    CFArrayRef snapshot = copySnapshot(list, &seed);
    if (!snapshot) {
        CFRelease(list);
        fprintf(stderr,
                "macwsworkspacectl: recent-document snapshot failed\n");
        return 1;
    }
    CFIndex count = CFArrayGetCount(snapshot);
    fprintf(stdout, "shared-file-list-ready items=%ld seed=%u\n",
            (long)count, seed);
    CFRelease(snapshot);
    CFRelease(list);
    return 0;
}

static int InspectSharedFileLists(void) {
    MacWSLSSharedFileListCreateFn createList =
        (MacWSLSSharedFileListCreateFn)dlsym(
            RTLD_DEFAULT, "LSSharedFileListCreate");
    MacWSLSSharedFileListCopySnapshotFn copySnapshot =
        (MacWSLSSharedFileListCopySnapshotFn)dlsym(
            RTLD_DEFAULT, "LSSharedFileListCopySnapshot");
    MacWSLSSharedFileListItemCopyDisplayNameFn copyDisplayName =
        (MacWSLSSharedFileListItemCopyDisplayNameFn)dlsym(
            RTLD_DEFAULT, "LSSharedFileListItemCopyDisplayName");
    MacWSLSSharedFileListItemCopyResolvedURLFn copyResolvedURL =
        (MacWSLSSharedFileListItemCopyResolvedURLFn)dlsym(
            RTLD_DEFAULT, "LSSharedFileListItemCopyResolvedURL");
    if (!createList || !copySnapshot || !copyDisplayName ||
        !copyResolvedURL) {
        fprintf(stderr,
                "macwsworkspacectl: SharedFileList inspection SPI "
                "unavailable\n");
        return 69;
    }

    static const struct {
        const char *label;
        const char *symbol;
    } listTypes[] = {
        {"favorite-items", "kLSSharedFileListFavoriteItems"},
        {"favorite-volumes", "kLSSharedFileListFavoriteVolumes"},
        {"recent-applications", "kLSSharedFileListRecentApplicationItems"},
        {"recent-documents", "kLSSharedFileListRecentDocumentItems"},
    };
    int failures = 0;
    for (size_t listIndex = 0;
         listIndex < sizeof(listTypes) / sizeof(listTypes[0]); listIndex++) {
        CFStringRef *type = (CFStringRef *)dlsym(
            RTLD_DEFAULT, listTypes[listIndex].symbol);
        if (!type || !*type) {
            fprintf(stdout, "shared-file-list-inspect list=%s unavailable\n",
                    listTypes[listIndex].label);
            continue;
        }
        CFTypeRef list = createList(kCFAllocatorDefault, *type, NULL);
        UInt32 seed = 0;
        CFArrayRef items = list ? copySnapshot(list, &seed) : NULL;
        if (!items) {
            fprintf(stdout,
                    "shared-file-list-inspect list=%s snapshot=nil\n",
                    listTypes[listIndex].label);
            if (list) CFRelease(list);
            failures++;
            continue;
        }
        fprintf(stdout,
                "shared-file-list-inspect list=%s items=%ld seed=%u\n",
                listTypes[listIndex].label,
                (long)CFArrayGetCount(items), seed);
        for (CFIndex itemIndex = 0;
             itemIndex < CFArrayGetCount(items); itemIndex++) {
            CFTypeRef item = CFArrayGetValueAtIndex(items, itemIndex);
            CFStringRef name = copyDisplayName(item);
            CFErrorRef error = NULL;
            CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
            // These are the least invasive flags Finder can use: resolution
            // may read an already-mounted path but cannot show UI or mount a
            // missing volume merely for this evidence probe.
            CFURLRef url = copyResolvedURL(item, 3, &error);
            CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - started;
            char nameBytes[PATH_MAX] = "(unnamed)";
            char urlBytes[PATH_MAX] = "(nil)";
            char errorDomain[256] = "none";
            CFIndex errorCode = 0;
            if (name) {
                (void)CFStringGetCString(name, nameBytes, sizeof(nameBytes),
                                         kCFStringEncodingUTF8);
            }
            if (url) {
                (void)CFURLGetFileSystemRepresentation(
                    url, true, (UInt8 *)urlBytes, sizeof(urlBytes));
            }
            if (error) {
                CFStringRef domain = CFErrorGetDomain(error);
                errorCode = CFErrorGetCode(error);
                if (domain) {
                    (void)CFStringGetCString(domain, errorDomain,
                                             sizeof(errorDomain),
                                             kCFStringEncodingUTF8);
                }
            }
            fprintf(stdout,
                    "shared-file-list-item list=%s index=%ld name=%s "
                    "url=%s error-domain=%s error-code=%ld elapsed-ms=%.3f\n",
                    listTypes[listIndex].label, (long)itemIndex, nameBytes,
                    urlBytes, errorDomain, (long)errorCode,
                    elapsed * 1000.0);
            if (!url) failures++;
            if (error) CFRelease(error);
            if (url) CFRelease(url);
            if (name) CFRelease(name);
        }
        CFRelease(items);
        CFRelease(list);
    }
    return failures == 0 ? 0 : 1;
}

static int InspectBookmarkPaths(void) {
    NSArray<NSString *> *paths = @[
        @"/Applications",
        @"/private/var",
        @"/private/var/root",
        @"/private/var/root/Desktop",
        @"/private/var/root/Documents",
        @"/private/var/root/Downloads",
        @"/Users/root",
    ];
    NSArray<NSURLResourceKey> *keys = @[
        NSURLVolumeURLKey,
        NSURLVolumeIdentifierKey,
        NSURLVolumeUUIDStringKey,
        NSURLVolumeNameKey,
        NSURLVolumeIsRootFileSystemKey,
        NSURLFileResourceIdentifierKey,
        NSURLDocumentIdentifierKey,
        NSURLCreationDateKey,
        NSURLContentModificationDateKey,
    ];
    for (NSString *path in paths) {
        NSURL *url = [NSURL fileURLWithPath:path];
        NSError *resourceError = nil;
        NSDictionary *values = [url resourceValuesForKeys:keys
                                                     error:&resourceError];
        fprintf(stdout, "bookmark-path path=%s resources-error=%s\n",
                path.fileSystemRepresentation,
                resourceError.description.UTF8String ?: "none");
        for (NSURLResourceKey key in keys) {
            id value = values[key];
            fprintf(stdout, "bookmark-resource path=%s key=%s class=%s "
                            "value=%s\n",
                    path.fileSystemRepresentation, key.UTF8String,
                    value ? object_getClassName(value) : "nil",
                    value ? [[value description] UTF8String] : "nil");
        }

        NSError *creationError = nil;
        NSData *bookmark = [url bookmarkDataWithOptions:0x20000000UL
                       includingResourceValuesForKeys:nil
                                        relativeToURL:nil
                                                error:&creationError];
        BOOL stale = NO;
        NSError *resolutionError = nil;
        NSURL *resolved = bookmark
            ? [NSURL URLByResolvingBookmarkData:bookmark
                                        options:0x300UL
                                  relativeToURL:nil
                            bookmarkDataIsStale:&stale
                                          error:&resolutionError]
            : nil;
        fprintf(stdout,
                "bookmark-roundtrip path=%s bytes=%lu stale=%d resolved=%s "
                "create-error=%s resolve-error=%s\n",
                path.fileSystemRepresentation, (unsigned long)bookmark.length,
                stale, resolved.path.fileSystemRepresentation ?: "(nil)",
                creationError.description.UTF8String ?: "none",
                resolutionError.description.UTF8String ?: "none");
    }
    return 0;
}

static int SetWallpaper(const char *pathBytes) {
    NSString *path = [NSString stringWithUTF8String:pathBytes ?: ""];
    if (path.length == 0 || ![[NSFileManager defaultManager]
            fileExistsAtPath:path]) {
        fprintf(stderr, "macwsworkspacectl: wallpaper does not exist: %s\n",
                pathBytes ?: "(null)");
        return 66;
    }

    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (screens.count == 0) {
        fprintf(stderr, "macwsworkspacectl: no AppKit screens are available\n");
        return 69;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    NSWorkspace *workspace = NSWorkspace.sharedWorkspace;
    for (NSScreen *screen in screens) {
        NSError *error = nil;
        BOOL changed = [workspace setDesktopImageURL:url
                                          forScreen:screen
                                            options:@{}
                                              error:&error];
        if (!changed) {
            fprintf(stderr,
                    "macwsworkspacectl: set wallpaper failed for %s: %s\n",
                    screen.localizedName.UTF8String ?: "(unnamed)",
                    error.description.UTF8String ?: "unknown error");
            return 1;
        }
    }
    fprintf(stdout, "wallpaper-ready screens=%lu path=%s\n",
            (unsigned long)screens.count, path.fileSystemRepresentation);
    return 0;
}

static int ShowLaunchpad(void) {
    static const char *const executable =
        "/System/Applications/Launchpad.app/Contents/MacOS/Launchpad";
    pid_t pid = 0;
    char *const arguments[] = {(char *)executable, NULL};
    int spawnError = posix_spawn(&pid, executable, NULL, NULL,
                                 arguments, environ);
    if (spawnError != 0) {
        fprintf(stderr,
                "macwsworkspacectl: Launchpad spawn failed: %s\n",
                strerror(spawnError));
        return spawnError;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return errno;
    if (!WIFEXITED(status)) return 1;
    return WEXITSTATUS(status);
}

typedef int32_t (*MainConnectionIDFn)(void);
typedef CFArrayRef (*CopyManagedDisplaySpacesFn)(int32_t);
typedef uint64_t (*SpaceCreateFn)(int32_t, int32_t, CFDictionaryRef);
typedef int32_t (*ManagedDisplaySetCurrentSpaceFn)(
    int32_t, CFStringRef, uint64_t);

static NSArray *CopyManagedSpaces(int32_t *connectionOut,
                                  NSUInteger *totalSpacesOut) {
    MainConnectionIDFn mainConnectionID =
        (MainConnectionIDFn)dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    if (!mainConnectionID) {
        mainConnectionID =
            (MainConnectionIDFn)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    }
    CopyManagedDisplaySpacesFn copySpaces =
        (CopyManagedDisplaySpacesFn)dlsym(
            RTLD_DEFAULT, "SLSCopyManagedDisplaySpaces");
    if (!copySpaces) {
        copySpaces = (CopyManagedDisplaySpacesFn)dlsym(
            RTLD_DEFAULT, "CGSCopyManagedDisplaySpaces");
    }
    if (!mainConnectionID || !copySpaces) {
        fprintf(stderr,
                "macwsworkspacectl: SkyLight managed-space API is "
                "unavailable (connection=%s spaces=%s)\n",
                mainConnectionID ? "yes" : "no",
                copySpaces ? "yes" : "no");
        return nil;
    }

    int32_t connection = mainConnectionID();
    CFArrayRef copied = copySpaces(connection);
    if (!copied) {
        fprintf(stderr,
                "macwsworkspacectl: SkyLight returned no managed spaces\n");
        return nil;
    }
    NSArray *displays = CFBridgingRelease(copied);
    NSUInteger totalSpaces = 0;
    for (id displayValue in displays) {
        if (![displayValue isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *display = displayValue;
        id spacesValue = display[@"Spaces"] ?: display[@"spaces"];
        if ([spacesValue isKindOfClass:NSArray.class])
            totalSpaces += [spacesValue count];
    }
    if (connectionOut) *connectionOut = connection;
    if (totalSpacesOut) *totalSpacesOut = totalSpaces;
    return displays;
}

static int ListSpaces(void) {
    NSUInteger totalSpaces = 0;
    NSArray *displays = CopyManagedSpaces(NULL, &totalSpaces);
    if (!displays) return 69;
    NSError *error = nil;
    NSData *propertyList = [NSPropertyListSerialization
        dataWithPropertyList:displays
                      format:NSPropertyListXMLFormat_v1_0
                     options:0
                       error:&error];
    fprintf(stdout, "managed-spaces displays=%lu spaces=%lu\n",
            (unsigned long)displays.count, (unsigned long)totalSpaces);
    if (propertyList) {
        fwrite(propertyList.bytes, 1, propertyList.length, stdout);
        fputc('\n', stdout);
    } else {
        fprintf(stdout, "%s\n",
                displays.description.UTF8String ?: "<unprintable>");
        fprintf(stderr,
                "macwsworkspacectl: managed-space property-list encoding "
                "failed: %s\n",
                error.description.UTF8String ?: "unknown error");
    }
    return totalSpaces > 0 ? 0 : 1;
}

static uint64_t ManagedSpaceID(NSDictionary *space) {
    id value = space[@"ManagedSpaceID"] ?: space[@"id64"] ?: space[@"wsid"];
    return [value respondsToSelector:@selector(unsignedLongLongValue)]
        ? [value unsignedLongLongValue] : 0;
}

static int SetCurrentSpace(const char *spaceBytes) {
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(spaceBytes ?: "", &end, 10);
    if (errno != 0 || !end || *end != '\0' || parsed == 0) return 64;

    int32_t connection = 0;
    NSArray *displays = CopyManagedSpaces(&connection, NULL);
    if (!displays) return 69;
    NSString *targetDisplay = nil;
    for (NSDictionary *display in displays) {
        NSArray *spaces = display[@"Spaces"] ?: display[@"spaces"];
        if (![spaces isKindOfClass:NSArray.class]) continue;
        for (NSDictionary *space in spaces) {
            if (ManagedSpaceID(space) != (uint64_t)parsed) continue;
            id identifier = display[@"Display Identifier"] ?:
                display[@"displayIdentifier"];
            if ([identifier isKindOfClass:NSString.class])
                targetDisplay = identifier;
            break;
        }
        if (targetDisplay) break;
    }
    if (!targetDisplay) {
        fprintf(stderr,
                "macwsworkspacectl: managed space %llu does not exist\n",
                parsed);
        return 66;
    }

    ManagedDisplaySetCurrentSpaceFn setCurrent =
        (ManagedDisplaySetCurrentSpaceFn)dlsym(
            RTLD_DEFAULT, "CGSManagedDisplaySetCurrentSpace");
    if (!setCurrent) setCurrent = (ManagedDisplaySetCurrentSpaceFn)dlsym(
        RTLD_DEFAULT, "SLSManagedDisplaySetCurrentSpace");
    if (!setCurrent) {
        fprintf(stderr,
                "macwsworkspacectl: SkyLight current-space API is unavailable\n");
        return 69;
    }
    // RE-confirmed in the target Ventura Dock arm64e image: call sites at
    // __TEXT+0x1ed9ac and +0x1f090c load (main connection, bridged display
    // identifier, uint64 space ID) into x0/x1/x2 immediately before calling
    // CGSManagedDisplaySetCurrentSpace. This command is a bounded recovery and
    // test primitive; production gestures still belong entirely to Dock.
    int32_t result = setCurrent(connection,
                                (__bridge CFStringRef)targetDisplay,
                                (uint64_t)parsed);
    if (result != 0) {
        fprintf(stderr,
                "macwsworkspacectl: set current space %llu failed: %d\n",
                parsed, result);
        return 1;
    }

    BOOL observed = NO;
    for (unsigned attempt = 0; attempt < 20 && !observed; attempt++) {
        NSArray *updated = CopyManagedSpaces(NULL, NULL);
        for (NSDictionary *display in updated) {
            NSDictionary *current = display[@"Current Space"] ?:
                display[@"currentSpace"];
            if (ManagedSpaceID(current) == (uint64_t)parsed) {
                observed = YES;
                break;
            }
        }
        if (!observed) usleep(50 * 1000);
    }
    fprintf(stdout,
            "current-space requested=%llu display=%s observed=%s\n",
            parsed, targetDisplay.UTF8String ?: "<unknown>",
            observed ? "yes" : "no");
    return observed ? 0 : 1;
}

static int EnsureNavigationSpaces(void) {
    int32_t connection = 0;
    NSUInteger before = 0;
    NSArray *displays = CopyManagedSpaces(&connection, &before);
    if (!displays || before == 0) return 69;
    if (before >= 2) {
        fprintf(stdout,
                "navigation-spaces ready before=%lu after=%lu created=0\n",
                (unsigned long)before, (unsigned long)before);
        return 0;
    }

    SpaceCreateFn createSpace = (SpaceCreateFn)dlsym(
        RTLD_DEFAULT, "CGSSpaceCreate");
    if (!createSpace) createSpace = (SpaceCreateFn)dlsym(
        RTLD_DEFAULT, "SLSSpaceCreate");
    if (!createSpace) {
        fprintf(stderr,
                "macwsworkspacectl: SkyLight space-create API is unavailable\n");
        return 69;
    }
    uint64_t createdSpace = createSpace(connection, 0, NULL);
    if (createdSpace == 0) {
        fprintf(stderr,
                "macwsworkspacectl: SkyLight failed to create the second "
                "navigation space\n");
        return 1;
    }

    NSUInteger after = 0;
    for (unsigned attempt = 0; attempt < 20; attempt++) {
        NSArray *updated = CopyManagedSpaces(NULL, &after);
        if (updated && after >= 2) break;
        usleep(50 * 1000);
    }
    fprintf(stdout,
            "navigation-spaces ready before=%lu after=%lu created=%llu\n",
            (unsigned long)before, (unsigned long)after,
            (unsigned long long)createdSpace);
    return after >= 2 ? 0 : 1;
}

static int CreateNavigationSpace(void) {
    int32_t connection = 0;
    NSUInteger before = 0;
    NSArray *displays = CopyManagedSpaces(&connection, &before);
    if (!displays || before == 0) return 69;

    SpaceCreateFn createSpace = (SpaceCreateFn)dlsym(
        RTLD_DEFAULT, "CGSSpaceCreate");
    if (!createSpace) createSpace = (SpaceCreateFn)dlsym(
        RTLD_DEFAULT, "SLSSpaceCreate");
    if (!createSpace) {
        fprintf(stderr,
                "macwsworkspacectl: SkyLight space-create API is unavailable\n");
        return 69;
    }

    // This is an explicit diagnostic/repair primitive for exercising the same
    // SkyLight mutation that Dock's Mission Control add button ultimately
    // requests.  It never substitutes for normal gesture or pointer input.
    uint64_t createdSpace = createSpace(connection, 0, NULL);
    if (createdSpace == 0) {
        fprintf(stderr,
                "macwsworkspacectl: SkyLight failed to create a navigation "
                "space\n");
        return 1;
    }

    NSUInteger after = 0;
    for (unsigned attempt = 0; attempt < 20; attempt++) {
        NSArray *updated = CopyManagedSpaces(NULL, &after);
        if (updated && after >= before + 1) break;
        usleep(50 * 1000);
    }
    fprintf(stdout,
            "navigation-space created before=%lu after=%lu id=%llu\n",
            (unsigned long)before, (unsigned long)after,
            (unsigned long long)createdSpace);
    return after >= before + 1 ? 0 : 1;
}

static int RegisterSettingsExtensions(BOOL registerRecords) {
    static NSString *const directoryPath =
        @"/System/Library/ExtensionKit/Extensions";
    static NSString *const settingsExtensionPoint =
        @"com.apple.Settings.extension.ui";
    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:directoryPath
                                               isDirectory:&directory] ||
        !directory) {
        fprintf(stderr,
                "macwsworkspacectl: settings extension directory is "
                "missing: %s\n", directoryPath.fileSystemRepresentation);
        return 66;
    }

    void *launchServices = dlopen(
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/"
        "Frameworks/LaunchServices.framework/Versions/A/LaunchServices",
        RTLD_NOW | RTLD_LOCAL);
    typedef int32_t (*LSRegisterPluginURL)(CFURLRef);
    LSRegisterPluginURL registerPluginURL = launchServices
        ? (LSRegisterPluginURL)dlsym(launchServices,
                                     "_LSRegisterPluginURL")
        : NULL;
    if (!registerPluginURL) {
        fprintf(stderr,
                "macwsworkspacectl: LaunchServices plug-in registrar is "
                "unavailable: %s\n", dlerror() ?: "unknown error");
        if (launchServices) dlclose(launchServices);
        return 69;
    }

    NSError *contentsError = nil;
    NSArray<NSURL *> *contents = [[NSFileManager defaultManager]
        contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directoryPath
                                            isDirectory:YES]
      includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                         options:NSDirectoryEnumerationSkipsHiddenFiles
                           error:&contentsError];
    if (!contents) {
        fprintf(stderr,
                "macwsworkspacectl: cannot enumerate settings extensions: "
                "%s\n", contentsError.description.UTF8String ?: "unknown");
        dlclose(launchServices);
        return 1;
    }
    contents = [contents sortedArrayUsingComparator:
        ^NSComparisonResult(NSURL *left, NSURL *right) {
            return [left.lastPathComponent localizedStandardCompare:
                    right.lastPathComponent];
        }];

    Class recordClass = NSClassFromString(@"LSApplicationExtensionRecord");
    if (!recordClass) {
        fprintf(stderr,
                "macwsworkspacectl: LSApplicationExtensionRecord is "
                "unavailable\n");
        dlclose(launchServices);
        return 69;
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *candidates =
        [NSMutableArray array];
    for (NSURL *url in contents) {
        @autoreleasepool {
            NSNumber *isDirectory = nil;
            [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey
                            error:nil];
            if (!isDirectory.boolValue ||
                ![url.pathExtension isEqualToString:@"appex"]) continue;

            NSBundle *bundle = [NSBundle bundleWithURL:url];
            NSDictionary *extensionAttributes =
                bundle.infoDictionary[@"EXAppExtensionAttributes"];
            NSString *extensionPoint =
                [extensionAttributes isKindOfClass:NSDictionary.class]
                    ? extensionAttributes[@"EXExtensionPointIdentifier"]
                    : nil;
            if (![extensionPoint isEqualToString:settingsExtensionPoint])
                continue;

            NSString *expectedIdentifier = bundle.bundleIdentifier;
            if (expectedIdentifier.length == 0) {
                fprintf(stderr,
                        "macwsworkspacectl: settings extension has no "
                        "bundle identifier path=%s\n",
                        url.path.fileSystemRepresentation);
                dlclose(launchServices);
                return 1;
            }

            if (registerRecords) {
                int32_t status = registerPluginURL((__bridge CFURLRef)url);
                if (status != 0) {
                    fprintf(stderr,
                            "macwsworkspacectl: stock LaunchServices "
                            "registration failed status=%d identifier=%s "
                            "path=%s\n", status,
                            expectedIdentifier.UTF8String,
                            url.path.fileSystemRepresentation);
                    dlclose(launchServices);
                    return 1;
                }
            }

            [candidates addObject:@{
                @"url": url,
                @"identifier": expectedIdentifier,
            }];
        }
    }

    // LaunchServices commits plug-in registrations as one database
    // transaction.  Runtime evidence on the iPad was explicit: registering
    // AppleIDSettings returned status 0, but an initWithURL:error: performed
    // before later plug-ins were submitted still returned -10814.  Aborting
    // there left the catalog with only the first five records and made System
    // Settings show only Appearance.  Once the remaining URLs were submitted,
    // the stock enumerator returned all 48 matching records.
    //
    // Keep status checking on every stock registration, then validate only
    // after the complete candidate set has been submitted.  No failure is
    // accepted as success: every record must still resolve to the exact
    // platform-1 identifier and URL before services are published.
    NSUInteger registeredCount = 0;
    NSUInteger validationAttempts = registerRecords ? 41 : 1;
    NSString *failedExpected = nil;
    NSString *failedIdentifier = nil;
    NSString *failedURL = nil;
    NSString *failedError = nil;
    unsigned failedPlatform = 0;
    for (NSUInteger attempt = 0; attempt < validationAttempts; attempt++) {
        registeredCount = 0;
        failedExpected = nil;
        failedIdentifier = nil;
        failedURL = nil;
        failedError = nil;
        failedPlatform = 0;
        for (NSDictionary<NSString *, id> *candidate in candidates) {
            @autoreleasepool {
                NSURL *url = candidate[@"url"];
                NSString *expectedIdentifier = candidate[@"identifier"];
                NSError *recordError = nil;
                id record = ((id (*)(id, SEL))objc_msgSend)(
                    (id)recordClass, sel_registerName("alloc"));
                record = record
                    ? ((id (*)(id, SEL, id, id *))objc_msgSend)(
                          record, sel_registerName("initWithURL:error:"),
                          url, &recordError)
                    : nil;
                NSString *identifier = record
                    ? ((id (*)(id, SEL))objc_msgSend)(
                          record, sel_registerName("bundleIdentifier"))
                    : nil;
                unsigned platform = record
                    ? ((unsigned (*)(id, SEL))objc_msgSend)(
                          record, sel_registerName("platform"))
                    : 0;
                NSURL *recordURL = record
                    ? ((id (*)(id, SEL))objc_msgSend)(
                          record, sel_registerName("URL"))
                    : nil;
                BOOL valid =
                    [identifier isEqualToString:expectedIdentifier] &&
                    platform == 1 &&
                    [recordURL.path isEqualToString:url.path];
                if (!valid) {
                    failedExpected = expectedIdentifier;
                    failedIdentifier = identifier;
                    failedPlatform = platform;
                    failedURL = recordURL.path;
                    failedError = recordError.description;
                    break;
                }
                registeredCount++;
            }
        }
        if (registeredCount == candidates.count) break;
        // Runtime-confirmed via launchservices-reactivation-ab.log on
        // 2026-08-23: _LSRegisterPluginURL accepted all 48 URLs, while an
        // immediate LSApplicationExtensionRecord lookup could still return
        // -10814 midway through the same asynchronous database commit. A
        // second process one second later verified all 48. Wait on the actual
        // records here for at most two seconds; success still requires every
        // exact identifier, platform and URL, so this is not a check bypass.
        if (attempt + 1 < validationAttempts) usleep(50 * 1000);
    }

    if (registeredCount != candidates.count) {
        fprintf(stderr,
                "macwsworkspacectl: registered settings record failed "
                "validation expected=%s identifier=%s platform=%u url=%s "
                "error=%s attempts=%lu\n",
                failedExpected.UTF8String ?: "<nil>",
                failedIdentifier.UTF8String ?: "<nil>", failedPlatform,
                failedURL.UTF8String ?: "<nil>",
                failedError.UTF8String ?: "none",
                (unsigned long)validationAttempts);
        dlclose(launchServices);
        return 1;
    }
    for (NSDictionary<NSString *, id> *candidate in candidates) {
        NSURL *url = candidate[@"url"];
        NSString *identifier = candidate[@"identifier"];
        fprintf(stdout,
                "settings-extension-%s identifier=%s platform=1 path=%s\n",
                registerRecords ? "ready" : "verified",
                identifier.UTF8String, url.path.fileSystemRepresentation);
    }

    NSUInteger candidateCount = candidates.count;
    if (candidateCount == 0 || registeredCount != candidateCount) {
        fprintf(stderr,
                "macwsworkspacectl: settings extension registration is "
                "incomplete candidates=%lu registered=%lu\n",
                (unsigned long)candidateCount,
                (unsigned long)registeredCount);
        dlclose(launchServices);
        return 1;
    }
    fprintf(stdout,
            "settings-extensions-%s candidates=%lu records=%lu\n",
            registerRecords ? "ready" : "verified",
            (unsigned long)candidateCount,
            (unsigned long)registeredCount);
    dlclose(launchServices);
    return 0;
}

static int CleanSeedLaunchServicesCatalog(void) {
    // Runtime-confirmed on the iPad on 2026-08-12: after the session lsd was
    // reloaded, trying to reactivate all 193 mounted application records with
    // one `lsregister -f` transaction left lsd at 86.8% CPU and Finder at
    // 34.5% CPU for more than nine minutes (one-minute load reached 105).
    // The existing cold-start fallback is the correct upstream recovery:
    // Ventura's stock `-kill -seed` rebuilt a coherent catalog in 8 seconds,
    // immediately verified all essential applications and all 48 Settings
    // extensions, and lsd settled to 5.5% CPU. Reuse that bounded transaction
    // instead of enumerating application bundles in this latency-sensitive
    // launch path.
    static NSString *const lsregisterPath =
        @"/System/Library/Frameworks/CoreServices.framework/Frameworks/"
         "LaunchServices.framework/Support/lsregister";
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager isExecutableFileAtPath:lsregisterPath]) {
        fprintf(stderr,
                "macwsworkspacectl: stock lsregister is missing: %s\n",
                lsregisterPath.fileSystemRepresentation);
        return 66;
    }

    pid_t child = 0;
    const char *arguments[] = {
        lsregisterPath.fileSystemRepresentation, "-kill", "-seed", NULL,
    };
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    int spawnError = posix_spawn(&child, arguments[0], NULL, NULL,
                                 (char *const *)arguments, environ);
    if (spawnError != 0) {
        fprintf(stderr,
                "macwsworkspacectl: lsregister spawn failed error=%d (%s)\n",
                spawnError, strerror(spawnError));
        return 128 + spawnError;
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno == EINTR) continue;
        fprintf(stderr,
                "macwsworkspacectl: lsregister wait failed errno=%d (%s)\n",
                errno, strerror(errno));
        return 127;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr,
                "macwsworkspacectl: clean lsregister seed failed status=%d\n",
                status);
        return WIFEXITED(status) ? WEXITSTATUS(status) : 126;
    }
    fprintf(stdout,
            "launchservices-catalog-clean-seeded elapsed_ms=%.0f "
            "route=stock-lsregister\n",
            (CFAbsoluteTimeGetCurrent() - start) * 1000.0);
    return 0;
}

static int RepairLaunchServicesCatalog(void) {
    int seedResult = CleanSeedLaunchServicesCatalog();
    if (seedResult != 0) return seedResult;
    int settingsResult = RegisterSettingsExtensions(NO);
    return settingsResult == 0 ? 0 : RegisterSettingsExtensions(YES);
}

static int VerifyLaunchServicesCatalog(void) {
    // A full `lsregister -f -apps system,local,user` walk takes roughly a
    // minute on the iPad rootfs.  Verify persistent LaunchServices state
    // through NSWorkspace's real bundle-ID lookup, so a matching source
    // fingerprint can reuse it after a cold bootstrap.
    // This is deliberately not a marker-only shortcut: every essential app
    // and all Settings panes must still resolve to their exact platform-1 URL.
    NSArray<NSString *> *requiredPaths = @[
        @"/System/Applications/Utilities/Terminal.app",
        @"/System/Applications/System Settings.app",
        @"/System/Library/CoreServices/Finder.app",
        @"/System/Library/CoreServices/Dock.app",
    ];
    NSMutableArray<NSString *> *paths = [requiredPaths mutableCopy];
    NSString *vscodePath = @"/Applications/Visual Studio Code.app";
    if ([[NSFileManager defaultManager] fileExistsAtPath:vscodePath])
        [paths addObject:vscodePath];

    for (NSString *path in paths) {
        NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
        NSBundle *bundle = [NSBundle bundleWithURL:url];
        NSString *expectedIdentifier = bundle.bundleIdentifier;
        NSURL *recordURL = expectedIdentifier.length
            ? [NSWorkspace.sharedWorkspace
                  URLForApplicationWithBundleIdentifier:expectedIdentifier]
            : nil;
        BOOL valid = expectedIdentifier.length != 0 &&
            [recordURL.path isEqualToString:path];
        if (!valid) {
            fprintf(stderr,
                    "macwsworkspacectl: application catalog validation "
                    "failed identifier=%s expectedURL=%s resolvedURL=%s\n",
                    expectedIdentifier.UTF8String ?: "<nil>",
                    path.UTF8String, recordURL.path.UTF8String ?: "<nil>");
            return 1;
        }
        fprintf(stdout,
                "application-record-verified identifier=%s path=%s\n",
                expectedIdentifier.UTF8String,
                recordURL.path.fileSystemRepresentation);
    }
    return RegisterSettingsExtensions(NO);
}

static int OpenApplication(const char *pathBytes) {
    NSString *path = [NSString stringWithUTF8String:pathBytes ?: ""];
    BOOL directory = NO;
    if (path.length == 0 ||
        ![[NSFileManager defaultManager] fileExistsAtPath:path
                                               isDirectory:&directory] ||
        !directory || ![path.pathExtension isEqualToString:@"app"]) {
        fprintf(stderr,
                "macwsworkspacectl: application bundle does not exist: %s\n",
                pathBytes ?: "(null)");
        return 66;
    }

    // LaunchServices supplies the open-application AppleEvent and activation
    // context that direct execution of many AppKit/SwiftUI bundle executables
    // does not.  Keep this synchronous API here so the short-lived helper can
    // report the actual NSRunningApplication PID before it exits.
    NSError *error = nil;
    NSRunningApplication *application =
        [NSWorkspace.sharedWorkspace
            launchApplicationAtURL:[NSURL fileURLWithPath:path]
                            options:NSWorkspaceLaunchDefault
                      configuration:@{}
                              error:&error];
    if (!application) {
        fprintf(stderr,
                "macwsworkspacectl: LaunchServices failed for %s: %s\n",
                path.fileSystemRepresentation,
                error.description.UTF8String ?: "unknown error");
        return 1;
    }
    fprintf(stdout, "application-ready pid=%d bundle=%s path=%s\n",
            application.processIdentifier,
            application.bundleIdentifier.UTF8String ?: "<unknown>",
            path.fileSystemRepresentation);
    return 0;
}

static int SessionStatus(void) {
    typedef CFDictionaryRef (*CopySessionDictionaryFunction)(void);
    static const char *const symbolNames[] = {
        "CGSSessionCopyCurrentSessionProperties",
        "CGSessionCopyCurrentDictionary",
    };
    for (size_t index = 0;
         index < sizeof(symbolNames) / sizeof(symbolNames[0]); index++) {
        CopySessionDictionaryFunction copySession =
            (CopySessionDictionaryFunction)dlsym(RTLD_DEFAULT,
                                                  symbolNames[index]);
        if (!copySession) {
            fprintf(stdout, "session-provider symbol=%s unavailable\n",
                    symbolNames[index]);
            continue;
        }
        CFDictionaryRef copied = copySession();
        if (!copied) {
            fprintf(stdout, "session-provider symbol=%s dictionary=<null>\n",
                    symbolNames[index]);
            continue;
        }
        NSDictionary *dictionary = CFBridgingRelease(copied);
        id loginDone = dictionary[@"kCGSessionLoginDoneKey"];
        id onConsole = dictionary[@"kCGSSessionOnConsoleKey"];
        id userID = dictionary[@"kCGSSessionUserIDKey"];
        id userName = dictionary[@"kCGSSessionUserNameKey"];
        fprintf(stdout,
                "session-provider symbol=%s login-done=%s on-console=%s "
                "uid=%s user=%s dictionary=%s\n",
                symbolNames[index],
                [[loginDone description] UTF8String] ?: "<missing>",
                [[onConsole description] UTF8String] ?: "<missing>",
                [[userID description] UTF8String] ?: "<missing>",
                [[userName description] UTF8String] ?: "<missing>",
                [[dictionary description] UTF8String] ?: "<invalid>");
    }
    return 0;
}

static int ActivateProcess(const char *pidBytes) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(pidBytes ?: "", &end, 10);
    if (errno != 0 || !end || *end != '\0' || parsed <= 1 ||
        parsed > INT32_MAX) {
        fprintf(stderr, "macwsworkspacectl: invalid PID: %s\n",
                pidBytes ?: "(null)");
        return 64;
    }
    pid_t pid = (pid_t)parsed;
    NSRunningApplication *application =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    BOOL workspaceActivated = application && [application activateWithOptions:
        (NSApplicationActivateAllWindows |
         NSApplicationActivateIgnoringOtherApps)];

    // Direct chroot launch targets can own valid SkyLight windows without an
    // LS process record.  Even when NSRunningApplication reports success, the
    // chroot can miss the Workspace callback that performs SkyLight's actual
    // front/key-window transaction.  Runtime evidence on 2026-08-11 showed
    // activateWithOptions: returning YES for Word while Finder remained the
    // visible menu owner and every traffic light stayed inactive.  Therefore
    // always complete the public HIServices transaction as well; neither call
    // synthesizes a window or mutates AppKit state directly.
    ProcessSerialNumber process = {0, 0};
    OSStatus lookup = GetProcessForPID(pid, &process);
    if (lookup != noErr) {
        if (workspaceActivated) {
            fprintf(stdout,
                    "application-active pid=%d route=NSRunningApplication "
                    "hiservices-lookup=%d\n", pid, (int)lookup);
            return 0;
        }
        fprintf(stderr,
                "macwsworkspacectl: GetProcessForPID(%d) failed: %d\n",
                pid, (int)lookup);
        return 1;
    }
    OSStatus activated = SetFrontProcessWithOptions(
        &process, kSetFrontProcessFrontWindowOnly |
                  kSetFrontProcessCausedByUser);
    if (activated != noErr) {
        if (workspaceActivated) {
            fprintf(stdout,
                    "application-active pid=%d route=NSRunningApplication "
                    "hiservices-set-front=%d\n", pid, (int)activated);
            return 0;
        }
        fprintf(stderr,
                "macwsworkspacectl: SetFrontProcessWithOptions(%d) "
                "failed: %d\n", pid, (int)activated);
        return 1;
    }
    fprintf(stdout,
            "application-active pid=%d route=%s+HIServices\n", pid,
            workspaceActivated ? "NSRunningApplication" : "direct");
    return 0;
}

static int ListWindows(const char *pidBytes) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(pidBytes ?: "", &end, 10);
    if (errno != 0 || !end || *end != '\0' || parsed <= 1 ||
        parsed > INT32_MAX) return 64;
    pid_t pid = (pid_t)parsed;
    CFArrayRef copied = CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll, kCGNullWindowID);
    NSArray<NSDictionary *> *windows = CFBridgingRelease(copied);
    NSUInteger count = 0;
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != pid) continue;
        count++;
        fprintf(stdout,
                "window pid=%d id=%u layer=%d onscreen=%s alpha=%s "
                "name=%s bounds=%s\n",
                pid, [window[(id)kCGWindowNumber] unsignedIntValue],
                [window[(id)kCGWindowLayer] intValue],
                [window[(id)kCGWindowIsOnscreen] boolValue] ? "yes" : "no",
                [[window[(id)kCGWindowAlpha] description] UTF8String]
                    ?: "<missing>",
                [[window[(id)kCGWindowName] description] UTF8String]
                    ?: "<unnamed>",
                [[window[(id)kCGWindowBounds] description] UTF8String]
                    ?: "<missing>");
    }
    fprintf(stdout, "window-count pid=%d count=%lu\n", pid,
            (unsigned long)count);
    return 0;
}

static int ReopenProcess(const char *pidBytes) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(pidBytes ?: "", &end, 10);
    if (errno != 0 || !end || *end != '\0' || parsed <= 1 ||
        parsed > INT32_MAX) return 64;
    pid_t pid = (pid_t)parsed;
    ProcessSerialNumber process = {0, 0};
    OSStatus status = GetProcessForPID(pid, &process);
    if (status != noErr) {
        fprintf(stderr,
                "macwsworkspacectl: GetProcessForPID(%d) failed before "
                "reopen: %d\n", pid, (int)status);
        return 1;
    }
    AEAddressDesc target = {typeNull, NULL};
    AppleEvent event = {typeNull, NULL};
    // Directly exec'd chroot applications have a valid HIServices process
    // record (GetProcessForPID and front-process activation both work), but
    // are absent from LaunchServices' PID-addressed AppleEvent registry.  A
    // typeKernelProcessID target consequently returns procNotFound (-600).
    // Address the same standard kAEReopenApplication event through the
    // process's real Carbon serial number instead of inventing an app-specific
    // show-window hook.
    status = AECreateDesc(typeProcessSerialNumber, &process, sizeof(process),
                          &target);
    if (status == noErr) {
        status = AECreateAppleEvent(kCoreEventClass, kAEReopenApplication,
                                    &target, kAutoGenerateReturnID,
                                    kAnyTransactionID, &event);
    }
    if (status == noErr) {
        status = AESendMessage(&event, NULL,
                               kAENoReply | kAECanSwitchLayer,
                               kAEDefaultTimeout);
    }
    AEDisposeDesc(&event);
    AEDisposeDesc(&target);
    if (status == procNotFound) {
        // launchdchrootexec children are missing only the cross-process
        // LaunchServices/AppleEvent endpoint. Their libmachook-owned app-input
        // endpoint runs on the real NSApplication main thread, where the
        // standard delegate reopen lifecycle can be delivered without an
        // app-specific show-window method.
        int socketFD = socket(AF_UNIX, SOCK_DGRAM, 0);
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        int pathLength = snprintf(address.sun_path, sizeof(address.sun_path),
                                  "/private/tmp/macws_app_input.%d.sock", pid);
        MacWSInputRecord record = {
            .magic = MACWS_INPUT_MAGIC,
            .version = MACWS_INPUT_VERSION,
            .kind = MacWSInputKindReopenApplication,
            .frameWidth = 1,
            .frameHeight = 1,
            .targetPID = pid,
            .source = MacWSInputSourceUnknown,
            .sampleSequence = 1,
        };
        ssize_t sent = -1;
        if (socketFD >= 0 && pathLength > 0 &&
            (size_t)pathLength < sizeof(address.sun_path)) {
            sent = sendto(socketFD, &record, sizeof(record), 0,
                          (const struct sockaddr *)&address,
                          sizeof(address));
        }
        int sendError = sent == (ssize_t)sizeof(record) ? 0 : errno;
        if (socketFD >= 0) close(socketFD);
        if (sendError == 0) {
            fprintf(stdout,
                    "application-reopen-sent pid=%d route=AppInputBridge\n",
                    pid);
            return 0;
        }
        fprintf(stderr,
                "macwsworkspacectl: reopen AppInputBridge fallback for pid "
                "%d failed: %s\n", pid, strerror(sendError));
    } else if (status == noErr) {
        fprintf(stdout, "application-reopen-sent pid=%d route=AppleEvent\n",
                pid);
        return 0;
    }
    if (status != noErr) {
        fprintf(stderr,
                "macwsworkspacectl: reopen AppleEvent for pid %d failed: %d\n",
                pid, (int)status);
        return 1;
    }
    return 1;
}

static int InspectAppKitReopen(void) {
    Class applicationClass = NSClassFromString(@"NSApplication");
    for (Class cursor = applicationClass; cursor; cursor = class_getSuperclass(cursor)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cursor, &count);
        for (unsigned int index = 0; index < count; index++) {
            SEL selector = method_getName(methods[index]);
            const char *name = sel_getName(selector);
            if (!name || (!strcasestr(name, "reopen") &&
                          !strcasestr(name, "untitled") &&
                          !strcasestr(name, "openfile") &&
                          !strcasestr(name, "coreevent"))) continue;
            IMP signedImplementation = method_getImplementation(methods[index]);
            void *implementation = ptrauth_strip(signedImplementation,
                                                  ptrauth_key_function_pointer);
            Dl_info image = {0};
            dladdr(implementation, &image);
            fprintf(stdout,
                    "appkit-method class=%s selector=%s types=%s imp=%p "
                    "image=%s offset=%#llx bytes=",
                    class_getName(cursor), name,
                    method_getTypeEncoding(methods[index]) ?: "<unknown>",
                    implementation, image.dli_fname ?: "<unknown>",
                    (unsigned long long)((uintptr_t)implementation -
                                         (uintptr_t)image.dli_fbase));
            const uint8_t *bytes = implementation;
            size_t byteCount = strcmp(name, "_handleAEReopen:") == 0
                ? 512 : 64;
            for (size_t byte = 0; byte < byteCount; byte++)
                fprintf(stdout, "%02x", bytes[byte]);
            fputc('\n', stdout);
        }
        free(methods);
    }
    return 0;
}

static int InspectUIKitMac(void) {
    void *image = dlopen(
        "/System/Library/PrivateFrameworks/UIKitMacHelper.framework/"
        "Versions/A/UIKitMacHelper", RTLD_NOW | RTLD_LOCAL);
    if (!image) {
        fprintf(stderr, "macwsworkspacectl: UIKitMacHelper dlopen failed: %s\n",
                dlerror());
        return 1;
    }
    NSApplication *hostApplication = NSApplication.sharedApplication;
    Class workspaceClass = objc_getClass("UINSWorkspace");
    id workspace = workspaceClass ? ((id (*)(id, SEL))objc_msgSend)(
        (id)workspaceClass, sel_registerName("sharedInstance")) : nil;
    id initialScreen = workspace ? ((id (*)(id, SEL))objc_msgSend)(
        workspace, sel_registerName("initialScreen")) : nil;
    id workspaceApplication = workspace ? ((id (*)(id, SEL))objc_msgSend)(
        workspace, sel_registerName("application")) : nil;
    Class delegateClass = objc_getClass("UINSApplicationDelegate");
    id sharedDelegate = delegateClass ? ((id (*)(id, SEL))objc_msgSend)(
        (id)delegateClass, sel_registerName("sharedDelegate")) : nil;
    fprintf(stdout,
            "uikitmac-state workspace=%s initial-screen=%s application=%s "
            "shared-delegate=%s ns-application=%s\n",
            workspace ? object_getClassName(workspace) : "nil",
            initialScreen ? object_getClassName(initialScreen) : "nil",
            workspaceApplication ? object_getClassName(workspaceApplication) :
                "nil",
            sharedDelegate ? object_getClassName(sharedDelegate) : "nil",
            hostApplication ? object_getClassName(hostApplication) : "nil");
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    for (unsigned int classIndex = 0; classIndex < classCount; classIndex++) {
        const char *className = class_getName(classes[classIndex]);
        if (!className || (strncmp(className, "UINS", 4) != 0 &&
                           strncmp(className, "_UINS", 5) != 0 &&
                           strcmp(className, "UIScreen") != 0 &&
                           strcmp(className, "UIApplication") != 0))
            continue;
        fprintf(stdout, "uikitmac-class name=%s\n", className);
        for (int meta = 0; meta <= 1; meta++) {
            Class owner = meta ? object_getClass(classes[classIndex])
                               : classes[classIndex];
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(owner, &methodCount);
            for (unsigned int methodIndex = 0;
                 methodIndex < methodCount; methodIndex++) {
                const char *name = sel_getName(method_getName(
                    methods[methodIndex]));
                BOOL primaryClass = strcmp(className, "UINSWorkspace") == 0 ||
                                    strcmp(className,
                                           "UINSApplicationDelegate") == 0;
                if (!name || (!primaryClass && !strcasestr(name, "scene") &&
                              !strcasestr(name, "screen") &&
                              !strcasestr(name, "launch") &&
                              !strcasestr(name, "display") &&
                              !strcasestr(name, "application") &&
                              !strcasestr(name, "run"))) continue;
                IMP signedImplementation = method_getImplementation(
                    methods[methodIndex]);
                void *implementation = ptrauth_strip(
                    signedImplementation, ptrauth_key_function_pointer);
                Dl_info ownerImage = {0};
                dladdr(implementation, &ownerImage);
                fprintf(stdout,
                        "uikitmac-method class=%s scope=%c selector=%s "
                        "types=%s image=%s offset=%#llx\n",
                        className, meta ? '+' : '-', name,
                        method_getTypeEncoding(methods[methodIndex]) ?:
                            "<unknown>",
                        ownerImage.dli_fname ?: "<unknown>",
                        (unsigned long long)((uintptr_t)implementation -
                            (uintptr_t)ownerImage.dli_fbase));
            }
            free(methods);
        }
    }
    free(classes);
    dlclose(image);
    return 0;
}

static int WriteFileIcon(const char *pathBytes, const char *outputBytes) {
    NSString *path = [NSString stringWithUTF8String:pathBytes ?: ""];
    NSString *output = [NSString stringWithUTF8String:outputBytes ?: ""];
    if (path.length == 0 || output.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        fprintf(stderr,
                "macwsworkspacectl: file-icon requires an existing path "
                "and an output PNG path\n");
        return 66;
    }

    NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:path];
    NSData *tiff = icon.TIFFRepresentation;
    NSBitmapImageRep *bitmap = tiff.length
        ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
    NSData *png = bitmap
        ? [bitmap representationUsingType:NSBitmapImageFileTypePNG
                               properties:@{}]
        : nil;
    if (!icon || png.length == 0 ||
        ![png writeToFile:output options:NSDataWritingAtomic error:nil]) {
        fprintf(stderr,
                "macwsworkspacectl: IconServices produced no writable icon "
                "for %s\n", path.fileSystemRepresentation);
        return 1;
    }

    fprintf(stdout,
            "file-icon-ready path=%s output=%s points=%.0fx%.0f "
            "pixels=%ldx%ld bytes=%lu representations=%lu\n",
            path.fileSystemRepresentation,
            output.fileSystemRepresentation,
            icon.size.width, icon.size.height,
            (long)bitmap.pixelsWide, (long)bitmap.pixelsHigh,
            (unsigned long)png.length,
            (unsigned long)icon.representations.count);
    return 0;
}

static int WriteFileThumbnail(const char *pathBytes,
                              const char *outputBytes) {
    NSString *path = [NSString stringWithUTF8String:pathBytes ?: ""];
    NSString *output = [NSString stringWithUTF8String:outputBytes ?: ""];
    if (path.length == 0 || output.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        fprintf(stderr,
                "macwsworkspacectl: file-thumbnail requires an existing "
                "path and an output PNG path\n");
        return 66;
    }

    NSURL *url = [NSURL fileURLWithPath:path];
    QLThumbnailGenerationRequest *request =
        [[QLThumbnailGenerationRequest alloc]
            initWithFileAtURL:url
                         size:CGSizeMake(512.0, 512.0)
                        scale:1.0
          representationTypes:
              QLThumbnailGenerationRequestRepresentationTypeThumbnail];
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block NSData *png = nil;
    __block NSError *generationError = nil;
    QLThumbnailGenerator *generator = QLThumbnailGenerator.sharedGenerator;
    [generator generateBestRepresentationForRequest:request
          completionHandler:^(QLThumbnailRepresentation *representation,
                              NSError *error) {
        if (representation.CGImage) {
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
                initWithCGImage:representation.CGImage];
            png = [bitmap representationUsingType:NSBitmapImageFileTypePNG
                                       properties:@{}];
        }
        generationError = error;
        dispatch_semaphore_signal(completed);
    }];

    long waitResult = dispatch_semaphore_wait(
        completed, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    if (waitResult != 0) {
        [generator cancelRequest:request];
        fprintf(stderr,
                "macwsworkspacectl: thumbnail request timed out for %s\n",
                path.fileSystemRepresentation);
        return 1;
    }
    if (png.length == 0 ||
        ![png writeToFile:output options:NSDataWritingAtomic error:nil]) {
        fprintf(stderr,
                "macwsworkspacectl: thumbnail generation failed for %s: "
                "%s\n",
                path.fileSystemRepresentation,
                generationError.description.UTF8String ?: "no image");
        return 1;
    }
    fprintf(stdout,
            "file-thumbnail-ready path=%s output=%s bytes=%lu\n",
            path.fileSystemRepresentation,
            output.fileSystemRepresentation,
            (unsigned long)png.length);
    return 0;
}

static int ResolveDocumentApplication(const char *path, const char *output) {
    NSURL *document = [NSURL fileURLWithPath:@(path)];
    NSURL *application = [NSWorkspace.sharedWorkspace
        URLForApplicationToOpenURL:document];
    if (!application.isFileURL || !application.path.isAbsolutePath) {
        fprintf(stderr, "resolve-document: no handler for %s\n", path);
        return 1;
    }
    NSDictionary *result = @{@"document_path": document.path,
                              @"application_path": application.path};
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:result
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (![data writeToFile:@(output) options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "resolve-document: %s\n", error.description.UTF8String);
        return 1;
    }
    fprintf(stdout, "resolve-document: %s -> %s\n", path,
            application.path.fileSystemRepresentation);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 &&
            strcmp(argv[1], "configure-airplay-power") == 0) {
            return ConfigureAirPlayPowerDefaults();
        }
        if (argc == 4 && strcmp(argv[1], "resolve-document") == 0)
            return ResolveDocumentApplication(argv[2], argv[3]);
        if (argc >= 2 && strcmp(argv[1], "set-wallpaper") == 0) {
            const char *path = argc >= 3 ? argv[2] :
                "/System/Library/Desktop Pictures/Solid Colors/Blue Violet.png";
            return SetWallpaper(path);
        }
        if (argc == 2 && strcmp(argv[1], "show-launchpad") == 0) {
            return ShowLaunchpad();
        }
        if (argc == 2 && strcmp(argv[1], "list-spaces") == 0) {
            return ListSpaces();
        }
        if (argc == 3 && strcmp(argv[1], "set-current-space") == 0) {
            return SetCurrentSpace(argv[2]);
        }
        if (argc == 2 &&
            strcmp(argv[1], "ensure-navigation-spaces") == 0) {
            return EnsureNavigationSpaces();
        }
        if (argc == 2 && strcmp(argv[1], "create-space") == 0) {
            return CreateNavigationSpace();
        }
        if (argc == 2 &&
            (strcmp(argv[1], "register-settings-extensions") == 0 ||
             strcmp(argv[1], "register-settings-extension") == 0)) {
            return RegisterSettingsExtensions(YES);
        }
        if (argc == 2 &&
            (strcmp(argv[1], "repair-launchservices-catalog") == 0 ||
             strcmp(argv[1], "reactivate-launchservices-catalog") == 0)) {
            return RepairLaunchServicesCatalog();
        }
        if (argc == 2 &&
            strcmp(argv[1], "verify-launchservices-catalog") == 0) {
            return VerifyLaunchServicesCatalog();
        }
        if (argc == 3 && strcmp(argv[1], "open-application") == 0) {
            return OpenApplication(argv[2]);
        }
        if (argc == 2 && strcmp(argv[1], "session-status") == 0) {
            return SessionStatus();
        }
        if (argc == 2 && strcmp(argv[1], "shared-file-list-ready") == 0) {
            return SharedFileListReady();
        }
        if (argc == 2 && strcmp(argv[1], "shared-file-list-inspect") == 0) {
            return InspectSharedFileLists();
        }
        if (argc == 2 && strcmp(argv[1], "bookmark-path-inspect") == 0) {
            return InspectBookmarkPaths();
        }
        if (argc == 3 && strcmp(argv[1], "activate-process") == 0) {
            return ActivateProcess(argv[2]);
        }
        if (argc == 3 && strcmp(argv[1], "list-windows") == 0) {
            return ListWindows(argv[2]);
        }
        if (argc == 3 && strcmp(argv[1], "reopen-process") == 0) {
            return ReopenProcess(argv[2]);
        }
        if (argc == 2 && strcmp(argv[1], "inspect-appkit-reopen") == 0) {
            return InspectAppKitReopen();
        }
        if (argc == 2 && strcmp(argv[1], "inspect-uikitmac") == 0) {
            return InspectUIKitMac();
        }
        if (argc == 4 && strcmp(argv[1], "file-icon") == 0) {
            return WriteFileIcon(argv[2], argv[3]);
        }
        if (argc == 4 && strcmp(argv[1], "file-thumbnail") == 0) {
            return WriteFileThumbnail(argv[2], argv[3]);
        }
        fprintf(stderr,
                "usage: macwsworkspacectl set-wallpaper [path] | "
                "show-launchpad | list-spaces | set-current-space ID | "
                "ensure-navigation-spaces | create-space | "
                "repair-launchservices-catalog | "
                "register-settings-extensions | "
                "verify-launchservices-catalog | "
                "shared-file-list-ready | "
                "shared-file-list-inspect | "
                "bookmark-path-inspect | "
                "configure-airplay-power | "
                "open-application /absolute/App.app | "
                "session-status | activate-process PID | list-windows PID | "
                "reopen-process PID | inspect-appkit-reopen | "
                "inspect-uikitmac | file-icon PATH OUTPUT.png | "
                "file-thumbnail PATH OUTPUT.png | "
                "resolve-document PATH OUTPUT.plist\n");
        return 64;
    }
}
