#import "MacWSInteropClient.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "MacWSHostDiagnostics.h"

#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "macws_control_protocol.h"
#include "macws_interop_protocol.h"
#include "macws_file_copy.h"

static NSString *const MacWSImportsHostRoot =
    @"/var/mnt/rootfs/Users/Shared/MacWS Imports";
static NSString *const MacWSRootFSHostPrefix = @"/var/mnt/rootfs";
static NSString *const MacWSArchiveVersionKey = @"version";
static NSString *const MacWSArchiveItemsKey = @"items";
static NSString *const MacWSArchiveRepresentationsKey = @"representations";
static NSString *const MacWSArchiveTypeKey = @"type";
static NSString *const MacWSArchiveDataKey = @"data";
static NSString *const MacWSArchiveFilePathKey = @"file_path";
static NSString *const MacWSObservedPasteboardChangeDefaultsKey =
    @"MacWSObservedPasteboardChange";
static const NSUInteger MacWSArchiveVersion = 1;

static __weak MacWSInteropClient *MacWSClipboardPublisher;
static uint64_t MacWSProcessOriginID;
static _Atomic uint64_t MacWSProcessGeneration;
// Accessed only on the main queue while applying UIKit pasteboard events.
static uint64_t MacWSLastRemoteOrigin;
static uint64_t MacWSLastRemoteGeneration;
static BOOL MacWSApplyingRemotePasteboard;

static NSError *MacWSError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"MacWSInterop" code:code userInfo:@{
        NSLocalizedDescriptionKey: message ?: @"互操作失败"
    }];
}

static void MacWSDigest(NSData *data, uint8_t output[16]) {
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    memcpy(output, digest, 16);
}

static BOOL MacWSAbsoluteArchivePath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || ![path hasPrefix:@"/"] ||
        [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
            MACWS_INTEROP_MAX_PATH_BYTES ||
        [path rangeOfString:@"\0"].location != NSNotFound) return NO;
    return [path.stringByStandardizingPath hasPrefix:@"/"];
}

static BOOL MacWSSharedTransferPath(NSString *path) {
    if (!MacWSAbsoluteArchivePath(path)) return NO;
    NSString *standard = path.stringByStandardizingPath;
    for (NSString *root in @[@"/Users/Shared/MacWS Imports",
                              @"/Users/Shared/MacWS Exports"]) {
        if ([standard isEqualToString:root] ||
            [standard hasPrefix:[root stringByAppendingString:@"/"]])
            return YES;
    }
    return NO;
}

// Only unpublished copies made for this provider transaction are disposable.
// Never remove an export or a provider's original on a failed multi-item drop.
static void MacWSRemoveUnpublishedProviderFiles(NSArray<NSArray *> *slots) {
    for (NSArray *slot in slots) {
        for (NSDictionary *representation in slot) {
            NSString *path = representation[MacWSArchiveFilePathKey];
            NSString *standard = path.stringByStandardizingPath;
            if (![standard hasPrefix:@"/Users/Shared/MacWS Imports/"])
                continue;
            NSString *hostPath = [MacWSRootFSHostPrefix
                stringByAppendingString:standard];
            [NSFileManager.defaultManager removeItemAtPath:hostPath error:nil];
        }
    }
}

// Treat the archive as untrusted input on both sides of the bridge. Returning
// normalized immutable containers keeps every consumer on the same bounded
// schema and prevents a malformed property list from reaching UIPasteboard.
static NSArray<NSDictionary *> *MacWSValidatedArchiveItems(NSData *archive,
                                                            NSError **error) {
    if (!archive.length || archive.length > MACWS_INTEROP_MAX_INLINE_BYTES) {
        if (error) *error = MacWSError(10, @"剪贴板归档为空或超过 64 MiB");
        return nil;
    }
    id root = [NSPropertyListSerialization propertyListWithData:archive
        options:NSPropertyListImmutable format:nil error:error];
    if (![root isKindOfClass:NSDictionary.class] ||
        ![root[MacWSArchiveVersionKey] isEqual:@(MacWSArchiveVersion)] ||
        ![root[MacWSArchiveItemsKey] isKindOfClass:NSArray.class]) {
        if (error && !*error) *error = MacWSError(11, @"剪贴板归档结构无效");
        return nil;
    }
    NSArray *items = root[MacWSArchiveItemsKey];
    if (!items.count || items.count > MACWS_INTEROP_MAX_ITEMS) {
        if (error) *error = MacWSError(12, @"剪贴板项目数量无效");
        return nil;
    }
    NSMutableArray *normalizedItems = [NSMutableArray array];
    NSUInteger representationCount = 0;
    NSUInteger inlineBytes = 0;
    for (id itemValue in items) {
        NSArray *representations = [itemValue isKindOfClass:NSDictionary.class]
            ? itemValue[MacWSArchiveRepresentationsKey] : nil;
        if (![representations isKindOfClass:NSArray.class] ||
            !representations.count) {
            if (error) *error = MacWSError(13, @"剪贴板项目没有有效格式");
            return nil;
        }
        NSMutableArray *normalizedRepresentations = [NSMutableArray array];
        for (id representationValue in representations) {
            if (++representationCount > MACWS_INTEROP_MAX_REPRESENTATIONS ||
                ![representationValue isKindOfClass:NSDictionary.class]) {
                if (error) *error = MacWSError(14, @"剪贴板格式数量无效");
                return nil;
            }
            NSString *type = representationValue[MacWSArchiveTypeKey];
            NSData *data = representationValue[MacWSArchiveDataKey];
            NSString *path = representationValue[MacWSArchiveFilePathKey];
            if (![type isKindOfClass:NSString.class] || !type.length ||
                [type lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >
                    MACWS_INTEROP_MAX_TYPE_BYTES ||
                ((data != nil) == (path != nil))) {
                if (error) *error = MacWSError(15, @"剪贴板格式描述无效");
                return nil;
            }
            if (data) {
                if (![data isKindOfClass:NSData.class] ||
                    data.length > MACWS_INTEROP_MAX_INLINE_BYTES - inlineBytes) {
                    if (error) *error = MacWSError(16, @"剪贴板内联数据越界");
                    return nil;
                }
                inlineBytes += data.length;
                [normalizedRepresentations addObject:@{
                    MacWSArchiveTypeKey: type, MacWSArchiveDataKey: data
                }];
            } else {
                if (!MacWSSharedTransferPath(path)) {
                    if (error) *error = MacWSError(17, @"剪贴板文件路径无效");
                    return nil;
                }
                [normalizedRepresentations addObject:@{
                    MacWSArchiveTypeKey: type,
                    MacWSArchiveFilePathKey: path.stringByStandardizingPath
                }];
            }
        }
        [normalizedItems addObject:@{
            MacWSArchiveRepresentationsKey: normalizedRepresentations
        }];
    }
    return normalizedItems;
}

static NSData *MacWSArchiveData(NSArray<NSDictionary *> *items,
                                NSError **error) {
    NSDictionary *root = @{
        MacWSArchiveVersionKey: @(MacWSArchiveVersion),
        MacWSArchiveItemsKey: items
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:root
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (data.length > MACWS_INTEROP_MAX_INLINE_BYTES) {
        if (error) *error = MacWSError(18, @"剪贴板归档超过 64 MiB");
        return nil;
    }
    return data;
}

static NSString *MacWSTransferFilename(NSString *suggestedName,
                                       NSString *type,
                                       NSUInteger index) {
    NSString *name = [suggestedName isKindOfClass:NSString.class]
        ? suggestedName.lastPathComponent : nil;
    if (!name.length || [name isEqualToString:@"."] ||
        [name isEqualToString:@".."]) {
        name = [NSString stringWithFormat:@"Imported-%lu",
            (unsigned long)index + 1];
    }
    if (!name.pathExtension.length && type.length) {
        UTType *uniformType = [UTType typeWithIdentifier:type];
        NSString *extension = uniformType.preferredFilenameExtension;
        if (extension.length) name = [name stringByAppendingPathExtension:extension];
    }
    return name;
}

static NSString *MacWSContentTypeForFileURL(NSURL *url) {
    NSNumber *isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    if (isDirectory.boolValue) return UTTypeFolder.identifier;
    UTType *type = url.pathExtension.length
        ? [UTType typeWithFilenameExtension:url.pathExtension] : nil;
    return type.identifier ?: UTTypeData.identifier;
}

static NSItemProvider *MacWSFileDragItemProvider(NSURL *url,
                                                 NSString *suggestedName) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL ||
        ![NSFileManager.defaultManager fileExistsAtPath:url.path]) return nil;

    NSNumber *isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    NSString *contentType = MacWSContentTypeForFileURL(url);
    NSString *acceptedFallback = isDirectory.boolValue
        ? UTTypeDirectory.identifier : UTTypeContent.identifier;
    NSItemProvider *provider = [NSItemProvider new];
    provider.suggestedName = suggestedName.lastPathComponent.length
        ? suggestedName.lastPathComponent : url.lastPathComponent;

    // Files 16.3 does not treat public.file-url as a generic import. Its
    // actual canHandle path checks a fixed list headed by public.content and
    // public.directory. Publish the inferred type first for fidelity, then a
    // file-backed generic type so an otherwise opaque Finder file (p12,
    // extensionless data, etc.) still has a representation Files accepts.
    // fileOptions=0 makes NSItemProvider copy the URL before this callback
    // returns, which is the supported cross-process lifetime boundary.
    NSMutableArray<NSString *> *types = [NSMutableArray arrayWithObject:
        contentType];
    if (![acceptedFallback isEqualToString:contentType])
        [types addObject:acceptedFallback];
    for (NSString *type in types) {
        [provider registerFileRepresentationForTypeIdentifier:type
            fileOptions:0
            visibility:NSItemProviderRepresentationVisibilityAll
            loadHandler:^NSProgress *(void (^handler)(NSURL *, BOOL,
                                                       NSError *)) {
                MacWSLog(@"interop-provider-file-request type=%@ file=%@",
                    type, url.lastPathComponent);
                handler(url, NO, nil);
                return nil;
            }];
    }

    UTType *uniformType = [UTType typeWithIdentifier:contentType];
    if ([uniformType conformsToType:UTTypeImage]) {
        // Runtime-confirmed in MacWSHost.log at 1789963603.927: the Finder
        // source offered Photos only file-backed public.png/public.content;
        // Photos rejected the drag before invoking either file loader
        // (UIDropOperationCancel, with no provider-file-request).  Offer an
        // abstract public.image data representation for Photos to negotiate
        // before requesting bytes, without replacing
        // the concrete file-backed type used by Files and Notes, so those
        // destinations retain the original filename and byte stream.
        [provider registerDataRepresentationForTypeIdentifier:
            UTTypeImage.identifier
            visibility:NSItemProviderRepresentationVisibilityAll
            loadHandler:^NSProgress *(void (^handler)(NSData *, NSError *)) {
                NSError *readError = nil;
                NSData *data = [NSData dataWithContentsOfURL:url
                    options:NSDataReadingMappedIfSafe error:&readError];
                MacWSLog(@"interop-provider-image-request file=%@ bytes=%lu error=%@",
                    url.lastPathComponent, (unsigned long)data.length,
                    readError ?: @"nil");
                handler(data, readError);
                return nil;
            }];
    }
    return provider;
}

static NSURL *MacWSHostDataContainerURL(void) {
    static NSURL *containerURL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *rootPath = @"/var/mobile/Containers/Data/Application";
        NSURL *root = [NSURL fileURLWithPath:rootPath isDirectory:YES];
        NSError *enumerationError = nil;
        NSArray<NSURL *> *candidates = [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:root
            includingPropertiesForKeys:nil options:0
            error:&enumerationError];
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        NSMutableArray<NSURL *> *allCandidates =
            [NSMutableArray arrayWithArray:candidates ?: @[]];

        // UIKit apps carrying no-container do not get their data-container URL
        // through NSHomeDirectory(). On the current rootless runtime Foundation
        // can also return an empty container-root enumeration even though the
        // unsandboxed process can traverse it. Use the same POSIX lookup that
        // succeeds from the device shell as a bounded fallback.
        if (!allCandidates.count) {
            DIR *directory = opendir(rootPath.fileSystemRepresentation);
            if (directory) {
                struct dirent *entry = NULL;
                while ((entry = readdir(directory)) != NULL) {
                    if (entry->d_name[0] == '.') continue;
                    NSString *name = [NSString stringWithUTF8String:entry->d_name];
                    if (!name.length) continue;
                    [allCandidates addObject:[root
                        URLByAppendingPathComponent:name isDirectory:YES]];
                }
                closedir(directory);
            }
        }

        NSError *lastMetadataError = nil;
        for (NSURL *candidate in allCandidates) {
            NSURL *metadata = [candidate URLByAppendingPathComponent:
                @".com.apple.mobile_container_manager.metadata.plist"];
            NSData *metadataData = [NSData dataWithContentsOfURL:metadata
                options:NSDataReadingMappedIfSafe error:&lastMetadataError];
            NSDictionary *values = metadataData ?
                [NSPropertyListSerialization propertyListWithData:metadataData
                    options:NSPropertyListImmutable format:nil
                    error:&lastMetadataError] : nil;
            if ([values[@"MCMMetadataIdentifier"]
                    isEqualToString:bundleIdentifier]) {
                containerURL = candidate;
                break;
            }
        }
        MacWSLog(@"interop-provider-container-resolve bundle=%@ candidates=%lu "
            "resolved=%@ enumeration-error=%@ metadata-error=%@",
            bundleIdentifier ?: @"(nil)", (unsigned long)allCandidates.count,
            containerURL.path ?: @"(nil)", enumerationError ?: @"nil",
            containerURL ? @"nil" : (lastMetadataError ?: @"nil"));
    });
    return containerURL;
}

static NSURL *MacWSStageDragProviderURL(NSURL *sourceURL, NSError **error) {
    NSURL *container = MacWSHostDataContainerURL();
    NSURL *cache = nil;
    if (container) {
        cache = [[container URLByAppendingPathComponent:@"Library"
                                            isDirectory:YES]
            URLByAppendingPathComponent:@"Caches/MacWSDragExports"
                             isDirectory:YES];
    } else {
        // MacWSHost intentionally carries no-container and therefore runs with
        // CFFIXED_USER_HOME=/var/mobile. Its own per-bundle cache is the
        // writable iOS-native staging area in that configuration. The
        // file-backed NSItemProvider copies from this URL for the receiver;
        // the raw path itself is never advertised.
        NSString *homePath = NSProcessInfo.processInfo.environment[
            @"CFFIXED_USER_HOME"] ?: NSHomeDirectory();
        NSString *standardHome = homePath.stringByStandardizingPath;
        if (![standardHome isEqualToString:@"/var/mobile"] &&
            ![standardHome hasPrefix:@"/var/mobile/"]) {
            if (error) *error = MacWSError(23,
                @"找不到可用的 macPad iOS 文件暂存目录");
            return nil;
        }
        cache = [NSURL fileURLWithPath:[[standardHome
            stringByAppendingPathComponent:@"Library/Caches"]
            stringByAppendingPathComponent:
                NSBundle.mainBundle.bundleIdentifier ?: @"com.macwsguide.host"]
                            isDirectory:YES];
        cache = [cache URLByAppendingPathComponent:@"MacWSDragExports"
                                       isDirectory:YES];
    }
    NSURL *batch = [cache URLByAppendingPathComponent:NSUUID.UUID.UUIDString
                                          isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:batch
                                withIntermediateDirectories:YES
                                                 attributes:nil error:error])
        return nil;
    NSString *name = sourceURL.lastPathComponent.length
        ? sourceURL.lastPathComponent : @"MacWS Export";
    NSURL *destination = [batch URLByAppendingPathComponent:name];
    if (![NSFileManager.defaultManager copyItemAtURL:sourceURL
                                               toURL:destination error:error])
        return nil;
    return destination;
}

static BOOL MacWSProviderPOSIXFallbackSourcePath(NSString *path) {
    if (!MacWSAbsoluteArchivePath(path)) return NO;
    NSString *standard = path.stringByStandardizingPath;
    // Runtime-confirmed in MacWSHost.log on 2026-09-10: Notes vends its real
    // callback-scoped attachment below one of these two container roots, and
    // NSFileManager can stat it even though its coordinated destination copy
    // fails with NSCocoaErrorDomain 513. Keep the unsandboxed POSIX fallback
    // restricted to iOS app/group containers; other URLs continue through
    // Foundation and their security-scoped extension only.
    for (NSString *root in @[@"/private/var/mobile/Containers",
                              @"/var/mobile/Containers"]) {
        if ([standard hasPrefix:[root stringByAppendingString:@"/"]])
            return YES;
    }
    return NO;
}

static BOOL MacWSProviderPOSIXCopyRegularFile(NSURL *sourceURL,
                                              NSURL *destinationURL,
                                              NSError **error) {
    NSString *sourcePath = sourceURL.path.stringByStandardizingPath;
    NSString *destinationPath =
        destinationURL.path.stringByStandardizingPath;
    NSString *destinationRoot =
        [MacWSImportsHostRoot.stringByStandardizingPath
            stringByAppendingString:@"/"];
    if (!sourceURL.isFileURL ||
        ![destinationPath hasPrefix:destinationRoot]) {
        if (error) *error = MacWSError(24,
            @"项目文件不在受支持的 iOS 提供器目录中");
        return NO;
    }

    int sourceFD = open(sourcePath.fileSystemRepresentation,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (sourceFD < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:errno userInfo:@{NSFilePathErrorKey: sourcePath}];
        return NO;
    }
    struct stat sourceStat = {0};
    if (fstat(sourceFD, &sourceStat) != 0 || !S_ISREG(sourceStat.st_mode) ||
        sourceStat.st_size < 0) {
        int savedErrno = errno ?: EINVAL;
        close(sourceFD);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:savedErrno userInfo:@{NSFilePathErrorKey: sourcePath}];
        return NO;
    }

    int destinationFD = open(destinationPath.fileSystemRepresentation,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (destinationFD < 0) {
        int savedErrno = errno;
        close(sourceFD);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:savedErrno userInfo:@{NSFilePathErrorKey: destinationPath}];
        return NO;
    }

    BOOL copied = MacWSCopyStableRegularFile(sourceFD, destinationFD, NULL) == 0;
    int savedErrno = copied ? 0 : errno;
    if (close(destinationFD) != 0 && copied) {
        copied = NO;
        savedErrno = errno;
    }
    close(sourceFD);
    if (!copied) {
        unlink(destinationPath.fileSystemRepresentation);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:(savedErrno ?: EIO)
            userInfo:@{NSFilePathErrorKey: destinationPath}];
    }
    return copied;
}

static BOOL MacWSProviderRootStageRegularFile(NSURL *sourceURL,
                                              NSURL *destinationURL,
                                              NSError **error) {
    NSString *sourcePath = sourceURL.path.stringByStandardizingPath;
    NSString *destinationPath =
        destinationURL.path.stringByStandardizingPath;
    if (!MacWSProviderPOSIXFallbackSourcePath(sourcePath)) return NO;

    xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
        dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!createMach) {
        if (error) *error = MacWSError(26, @"root 暂存服务不可用");
        return NO;
    }
    dispatch_queue_t queue = dispatch_queue_create(
        "com.macwsguide.host.provider-root-stage", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t connection = createMach(
        MACWS_CONTROL_SERVICE, queue, 0);
    if (!connection) {
        if (error) *error = MacWSError(26, @"无法连接 root 暂存服务");
        return NO;
    }
    // xpc_connection_resume() requires every non-listener connection to have
    // an event handler, even when the only application message uses the
    // synchronous reply API below.  The two Notes drops captured in
    // MacWSHost-2026-09-11-013232/013239.ips both trap in
    // _xpc_connection_activate_if_needed -> xpc_connection_resume with
    // _xpc_api_misuse before hostd can receive the request.  Install the
    // required handler at the connection lifecycle boundary; synchronous
    // reply/error interpretation remains below.
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        (void)event;
    });
    xpc_connection_resume(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_CONTROL_KEY_OP,
                              MACWS_CONTROL_OP_STAGE_PROVIDER_FILE);
    xpc_dictionary_set_string(request,
        MACWS_CONTROL_KEY_PROVIDER_SOURCE_PATH,
        sourcePath.fileSystemRepresentation);
    xpc_dictionary_set_string(request,
        MACWS_CONTROL_KEY_PROVIDER_DESTINATION_PATH,
        destinationPath.fileSystemRepresentation);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(
        connection, request);
    BOOL copied = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
        xpc_dictionary_get_bool(reply, "ok");
    if (!copied && error) {
        const char *message = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY
            ? xpc_dictionary_get_string(reply, "message") : NULL;
        NSString *description = message
            ? [NSString stringWithUTF8String:message] : @"root 暂存服务没有响应";
        *error = MacWSError(26, description ?: @"root 暂存服务失败");
    }
    xpc_connection_cancel(connection);
    return copied;
}

static BOOL MacWSStageProviderURL(NSURL *url, NSString *suggestedName,
                                  NSString *type, NSUInteger index,
                                  NSString **chrootPath, NSError **error) {
    if (![url isKindOfClass:NSURL.class] || !url.isFileURL) {
        if (error) *error = MacWSError(19, @"项目没有可读取的文件表示");
        return NO;
    }
    NSString *batch = [MacWSImportsHostRoot stringByAppendingPathComponent:
        NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:batch
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:error])
        return NO;
    NSString *name = MacWSTransferFilename(
        suggestedName.length ? suggestedName : url.lastPathComponent,
        type, index);
    NSURL *destination = [NSURL fileURLWithPath:
        [batch stringByAppendingPathComponent:name]];
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *foundationError = nil;
    NSNumber *regular = nil;
    [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
    BOOL copied = regular.boolValue
        ? MacWSProviderPOSIXCopyRegularFile(url, destination, &foundationError)
        : [NSFileManager.defaultManager copyItemAtURL:url toURL:destination
                                               error:&foundationError];
    NSError *fallbackError = nil;
    if (!copied && MacWSProviderPOSIXFallbackSourcePath(url.path)) {
        // The destination may exist partially after a failed coordinated
        // copy. Remove only this freshly generated batch member before using
        // O_EXCL for the streaming fallback.
        unlink(destination.path.fileSystemRepresentation);
        copied = MacWSProviderPOSIXCopyRegularFile(url, destination,
                                                   &fallbackError);
        MacWSLog(@"interop-provider-posix-stage source=%@ destination=%@ accepted=%@ foundation-error=%@ fallback-error=%@",
            url.path, destination.path, copied ? @"YES" : @"NO",
            foundationError ?: @"nil", fallbackError ?: @"nil");
    }
    NSError *rootStageError = nil;
    if (!copied && MacWSProviderPOSIXFallbackSourcePath(url.path)) {
        unlink(destination.path.fileSystemRepresentation);
        copied = MacWSProviderRootStageRegularFile(
            url, destination, &rootStageError);
        MacWSLog(@"interop-provider-root-stage source=%@ destination=%@ accepted=%@ error=%@",
            url.path, destination.path, copied ? @"YES" : @"NO",
            rootStageError ?: @"nil");
    }
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!copied) {
        // This UUID batch belongs only to this failed import, never the source.
        [NSFileManager.defaultManager removeItemAtPath:batch error:nil];
        if (error) *error = rootStageError ?: fallbackError ?: foundationError ?:
            MacWSError(25, @"无法复制项目提供器文件");
        return NO;
    }
    if (error) *error = nil;
    if (chrootPath) *chrootPath = [destination.path substringFromIndex:
        MacWSRootFSHostPrefix.length];
    return YES;
}

static BOOL MacWSStageProviderData(NSData *data, NSString *suggestedName,
                                   NSString *type, NSUInteger index,
                                   NSString **chrootPath, NSError **error) {
    if (![data isKindOfClass:NSData.class] || !data.length ||
        data.length > MACWS_INTEROP_MAX_INLINE_BYTES) return NO;
    NSString *batch = [MacWSImportsHostRoot stringByAppendingPathComponent:
        NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:batch
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:error])
        return NO;
    NSString *name = MacWSTransferFilename(suggestedName, type, index);
    NSURL *destination = [NSURL fileURLWithPath:
        [batch stringByAppendingPathComponent:name]];
    if (![data writeToURL:destination options:NSDataWritingAtomic error:error])
        return NO;
    if (chrootPath) *chrootPath = [destination.path substringFromIndex:
        MacWSRootFSHostPrefix.length];
    return YES;
}

static BOOL MacWSSlotHasFileURL(NSArray<NSDictionary *> *slot) {
    for (NSDictionary *representation in slot) {
        if ([representation[MacWSArchiveTypeKey]
                isEqualToString:UTTypeFileURL.identifier] &&
            representation[MacWSArchiveFilePathKey]) return YES;
    }
    return NO;
}

static NSString *MacWSPreferredMaterializationType(
    NSArray<NSString *> *types) {
    NSString *bestType = nil;
    NSInteger bestScore = NSIntegerMin;
    for (NSString *type in types) {
        if (![type isKindOfClass:NSString.class] || !type.length ||
            [type isEqualToString:UTTypeFileURL.identifier] ||
            [type hasPrefix:@"com.apple.finder."]) continue;
        UTType *uniformType = [UTType typeWithIdentifier:type];
        NSInteger score = uniformType ? 10 : 1;
        if ([type isEqualToString:UTTypeItem.identifier] ||
            [type isEqualToString:UTTypeContent.identifier] ||
            [type isEqualToString:UTTypeData.identifier]) score = 0;
        if (uniformType.preferredFilenameExtension.length) score += 20;
        if ([uniformType conformsToType:UTTypeText]) score += 30;
        if ([uniformType conformsToType:UTTypePDF]) score += 40;
        if ([uniformType conformsToType:UTTypeAudio] ||
            [uniformType conformsToType:UTTypeMovie]) score += 50;
        if ([uniformType conformsToType:UTTypeImage]) score += 60;
        if (score > bestScore) {
            bestScore = score;
            bestType = type;
        }
    }
    return bestType;
}

static BOOL MacWSStageURLs(NSArray<NSURL *> *urls,
                           NSArray<NSURL *> **stagedURLs,
                           NSArray<NSString *> **chrootPaths,
                           NSError **error) {
    NSString *batch = [MacWSImportsHostRoot stringByAppendingPathComponent:
        NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:batch
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:error])
        return NO;
    NSMutableArray *staged = [NSMutableArray array];
    NSMutableArray *paths = [NSMutableArray array];
    NSUInteger limit = MIN(urls.count, MACWS_INTEROP_MAX_ITEMS);
    for (NSUInteger index = 0; index < limit; index++) {
        NSURL *url = urls[index];
        if (![url isKindOfClass:NSURL.class] || !url.isFileURL) continue;
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *name = url.lastPathComponent.length ? url.lastPathComponent :
            [NSString stringWithFormat:@"Imported-%lu", (unsigned long)index + 1];
        NSString *stem = name.stringByDeletingPathExtension;
        NSString *extension = name.pathExtension;
        NSString *candidate = name;
        NSUInteger suffix = 2;
        while ([NSFileManager.defaultManager fileExistsAtPath:
                [batch stringByAppendingPathComponent:candidate]]) {
            NSString *numbered = [NSString stringWithFormat:@"%@-%lu",
                stem.length ? stem : @"Imported", (unsigned long)suffix++];
            candidate = extension.length
                ? [numbered stringByAppendingPathExtension:extension] : numbered;
        }
        NSURL *destination = [NSURL fileURLWithPath:
            [batch stringByAppendingPathComponent:candidate]];
        BOOL copied = [NSFileManager.defaultManager copyItemAtURL:url
                                                            toURL:destination
                                                            error:error];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (!copied) return NO;
        [staged addObject:destination];
        [paths addObject:[destination.path substringFromIndex:
            MacWSRootFSHostPrefix.length]];
    }
    if (!staged.count) {
        if (error) *error = MacWSError(19, @"没有可导入的文件");
        return NO;
    }
    if (stagedURLs) *stagedURLs = staged;
    if (chrootPaths) *chrootPaths = paths;
    return YES;
}

// On iPadOS 16 an NSItemProvider can materialize public.file-url as a small
// binary-plist wrapper and return the wrapper's temporary URL from loadItem:.
// Its first plist value is the source URL string. Decode that representation
// before staging so the bridge copies the user's file, not the URL wrapper.
static NSURL *MacWSResolvedProviderFileURL(id item) {
    NSURL *url = [item isKindOfClass:NSURL.class] ? item : nil;
    if (!url && [item isKindOfClass:NSString.class])
        url = [NSURL URLWithString:item];
    NSData *serialized = [item isKindOfClass:NSData.class] ? item : nil;
    if (!serialized && url.isFileURL) {
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (size.unsignedLongLongValue > 0 &&
            size.unsignedLongLongValue <= MACWS_INTEROP_MAX_PATH_BYTES * 4) {
            serialized = [NSData dataWithContentsOfURL:url
                options:NSDataReadingMappedIfSafe error:nil];
        }
    }
    if (serialized.length) {
        id value = [NSPropertyListSerialization propertyListWithData:serialized
            options:NSPropertyListImmutable format:nil error:nil];
        NSString *string = nil;
        if ([value isKindOfClass:NSArray.class] && [value count] &&
            [[(NSArray *)value firstObject] isKindOfClass:NSString.class]) {
            string = [(NSArray *)value firstObject];
        } else if ([value isKindOfClass:NSString.class]) {
            string = value;
        }
        NSURL *decoded = string.length ? [NSURL URLWithString:string] : nil;
        if (decoded.isFileURL) url = decoded;
    }
    return url.isFileURL ? url : nil;
}

@interface MacWSInteropClient ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) xpc_connection_t connection;
@property(nonatomic, readwrite, getter=isConnected) BOOL connected;
@property(nonatomic) NSInteger lastLocalPasteboardChange;
@property(nonatomic) NSInteger pendingLocalPasteboardChange;
@property(nonatomic) uint64_t localPublishSerial;
@property(nonatomic) dispatch_source_t pasteboardPollTimer;
@end

@implementation MacWSInteropClient

+ (void)importDocumentURL:(NSURL *)url
              completion:(void (^)(NSString *, NSError *))completion {
    // Acquire the extension on receipt, not after dispatching the copy.
    BOOL scoped = [url startAccessingSecurityScopedResource];
    static dispatch_queue_t imports;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        imports = dispatch_queue_create("com.macwsguide.host.open-in",
                                         DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(imports, ^{
        __block NSString *path = nil;
        __block NSError *stageError = nil;
        NSError *coordinationError = nil;
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc]
            initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:url options:0
            error:&coordinationError byAccessor:^(NSURL *readableURL) {
                MacWSStageProviderURL(readableURL, url.lastPathComponent,
                    UTTypeData.identifier, 0, &path, &stageError);
            }];
        if (scoped) [url stopAccessingSecurityScopedResource];
        MacWSLog(@"open-in stage source=%@ destination=%@ result=%@ error=%@",
            url.lastPathComponent, path ?: @"", path ? @"ready" : @"failed",
            coordinationError ?: stageError ?: @"nil");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(path, coordinationError ?: stageError);
        });
    });
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("com.macwsguide.host.interop-client",
                                       DISPATCH_QUEUE_SERIAL);
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            arc4random_buf(&MacWSProcessOriginID, sizeof(MacWSProcessOriginID));
            if (!MacWSProcessOriginID) MacWSProcessOriginID = 1;
        });
        NSNumber *observed = [NSUserDefaults.standardUserDefaults
            objectForKey:MacWSObservedPasteboardChangeDefaultsKey];
        _lastLocalPasteboardChange = observed ? observed.integerValue : -1;
        _pendingLocalPasteboardChange = -1;
        if (!MacWSClipboardPublisher) MacWSClipboardPublisher = self;
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(localPasteboardChanged:)
            name:UIPasteboardChangedNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(applicationDidBecomeActive:)
            name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(applicationDidEnterBackground:)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self
            selector:@selector(localPasteboardChanged:)
            name:UISceneDidActivateNotification object:nil];
        if (MacWSClipboardPublisher == self) [self startPasteboardPolling];
    }
    return self;
}

- (void)dealloc {
    if (_pasteboardPollTimer) dispatch_source_cancel(_pasteboardPollTimer);
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self invalidate];
}

- (void)startPasteboardPolling {
    if (self.pasteboardPollTimer) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
        0, 0, dispatch_get_main_queue());
    if (!timer) return;
    self.pasteboardPollTimer = timer;
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
        750 * NSEC_PER_MSEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        MacWSInteropClient *strongSelf = weakSelf;
        if (!strongSelf || MacWSClipboardPublisher != strongSelf ||
            MacWSApplyingRemotePasteboard ||
            UIApplication.sharedApplication.applicationState !=
                UIApplicationStateActive) return;
        NSInteger change = UIPasteboard.generalPasteboard.changeCount;
        if (change != strongSelf.lastLocalPasteboardChange &&
            change != strongSelf.pendingLocalPasteboardChange) {
            // UIPasteboardChangedNotification is not a sufficient cross-app
            // witness in macPad's multi-scene layout: runtime logs showed a
            // UIScene becoming active without an application activation or a
            // pasteboard notification. Poll only the cheap metadata counter;
            // payload access still happens once, after a new count is seen.
            [strongSelf localPasteboardChanged:nil];
        }
    });
    dispatch_resume(timer);
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    // A foreground Scene is the only consumer of clipboard convergence.
    // UIKit can keep this entitled Host resident after the last Scene has
    // backgrounded, so an event-handler state check alone still wakes the
    // process every 750 ms. Cancel the source at the application lifecycle
    // boundary; the active transition below recreates it without changing
    // clipboard ownership or the XPC subscription.
    if (MacWSClipboardPublisher != self) return;
    dispatch_source_t timer = self.pasteboardPollTimer;
    self.pasteboardPollTimer = nil;
    if (timer) dispatch_source_cancel(timer);
    self.localPublishSerial++;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    if (MacWSClipboardPublisher == self) [self startPasteboardPolling];
    [self localPasteboardChanged:notification];
}

- (void)publishStatus:(NSString *)status connected:(BOOL)connected {
    self.connected = connected;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate interopClient:self statusChanged:status connected:connected];
    });
}

- (BOOL)ensureConnection {
    if (self.connection) return YES;
    xpc_connection_t (*createMach)(const char *, dispatch_queue_t, uint64_t) =
        dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!createMach) return NO;
    xpc_connection_t connection = createMach(MACWS_INTEROP_SERVICE,
                                              self.queue, 0);
    if (!connection) return NO;
    __weak typeof(self) weakSelf = self;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        [weakSelf handleEvent:event];
    });
    xpc_connection_resume(connection);
    self.connection = connection;
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, MACWS_INTEROP_KEY_OP,
                              MACWS_INTEROP_OP_HELLO);
    xpc_dictionary_set_uint64(hello, MACWS_INTEROP_KEY_PROTOCOL_VERSION,
                              MACWS_INTEROP_VERSION);
    xpc_connection_send_message(connection, hello);
    return YES;
}

- (void)connect {
    dispatch_async(self.queue, ^{
        if (!self.isConnected && ![self ensureConnection])
            [self publishStatus:@"macOS 互操作服务离线" connected:NO];
    });
}

- (void)sendSubscription {
    if (!self.connection) return;
    xpc_object_t subscribe = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(subscribe, MACWS_INTEROP_KEY_OP,
                              MACWS_INTEROP_OP_SUBSCRIBE);
    xpc_connection_send_message(self.connection, subscribe);
}

- (void)localPasteboardChanged:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self localPasteboardChanged:notification];
        });
        return;
    }
    if (!MacWSClipboardPublisher) {
        MacWSClipboardPublisher = self;
        [self startPasteboardPolling];
    }
    UIApplicationState state =
        UIApplication.sharedApplication.applicationState;
    NSInteger change = UIPasteboard.generalPasteboard.changeCount;
    MacWSDiagnosticLog(@"interop-local-pasteboard notification=%@ change=%ld last=%ld "
        "state=%ld applying-remote=%@ publisher=%@",
        notification.name ?: @"manual", (long)change,
        (long)self.lastLocalPasteboardChange, (long)state,
        MacWSApplyingRemotePasteboard ? @"YES" : @"NO",
        MacWSClipboardPublisher == self ? @"YES" : @"NO");
    if (MacWSClipboardPublisher != self || MacWSApplyingRemotePasteboard ||
        state != UIApplicationStateActive) return;
    if (change == self.lastLocalPasteboardChange ||
        change == self.pendingLocalPasteboardChange) return;
    self.pendingLocalPasteboardChange = change;
    uint64_t serial = ++self.localPublishSerial;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (serial == self.localPublishSerial &&
            MacWSClipboardPublisher == self) [self publishGeneralPasteboard];
    });
}

- (NSArray<NSDictionary *> *)archiveItemsForUIKitItems:(NSArray *)pasteItems
                                             stagedURLs:(NSArray<NSURL *> **)outURLs
                                                   error:(NSError **)error {
    NSMutableArray *result = [NSMutableArray array];
    NSMutableArray *allStaged = [NSMutableArray array];
    NSUInteger representationCount = 0;
    NSUInteger inlineBytes = 0;
    for (NSDictionary *item in pasteItems) {
        if (result.count >= MACWS_INTEROP_MAX_ITEMS ||
            ![item isKindOfClass:NSDictionary.class]) break;
        NSMutableArray *representations = [NSMutableArray array];
        for (NSString *originalType in item) {
            if (representationCount >= MACWS_INTEROP_MAX_REPRESENTATIONS ||
                ![originalType isKindOfClass:NSString.class] ||
                !originalType.length) break;
            NSString *type = originalType;
            id value = item[type];
            NSDictionary *representation = nil;
            NSURL *fileURL = [value isKindOfClass:NSURL.class] ? value : nil;
            if (!fileURL && [type isEqualToString:UTTypeFileURL.identifier])
                fileURL = MacWSResolvedProviderFileURL(value);
            if (!fileURL && [value isKindOfClass:NSString.class] &&
                [type isEqualToString:UTTypeFileURL.identifier]) {
                NSURL *candidate = [NSURL URLWithString:value];
                if (candidate.isFileURL) fileURL = candidate;
            }
            if (fileURL.isFileURL) {
                NSArray *staged = nil, *paths = nil;
                if (!MacWSStageURLs(@[fileURL], &staged, &paths, error))
                    return nil;
                [allStaged addObjectsFromArray:staged];
                representation = @{
                    MacWSArchiveTypeKey: type,
                    MacWSArchiveFilePathKey: paths.firstObject
                };
            } else {
                NSData *data = nil;
                if ([value isKindOfClass:NSData.class]) data = value;
                else if ([value isKindOfClass:NSString.class])
                    data = [value dataUsingEncoding:NSUTF8StringEncoding];
                else if ([value isKindOfClass:NSURL.class])
                    data = [[value absoluteString]
                        dataUsingEncoding:NSUTF8StringEncoding];
                else if ([value isKindOfClass:UIImage.class]) {
                    data = UIImagePNGRepresentation(value);
                    type = UTTypePNG.identifier;
                }
                if (!data || data.length >
                    MACWS_INTEROP_MAX_INLINE_BYTES - inlineBytes) continue;
                inlineBytes += data.length;
                representation = @{
                    MacWSArchiveTypeKey: type, MacWSArchiveDataKey: data
                };
            }
            if (representation) {
                [representations addObject:representation];
                representationCount++;
            }
        }
        if (representations.count) [result addObject:@{
            MacWSArchiveRepresentationsKey: representations
        }];
    }
    if (!result.count) {
        if (error) *error = MacWSError(20, @"剪贴板中没有可同步的格式");
        return nil;
    }
    if (outURLs) *outURLs = allStaged;
    return result;
}

- (void)sendArchiveData:(NSData *)archive
              completion:(void (^)(BOOL, NSError *))completion {
    dispatch_async(self.queue, ^{
        if (![self ensureConnection]) {
            NSError *error = MacWSError(21, @"macOS 互操作服务离线");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, error);
            });
            return;
        }
        MacWSInteropItemDescriptor descriptor = {
            .magic = MACWS_INTEROP_MAGIC,
            .version = MACWS_INTEROP_VERSION,
            .size = sizeof(MacWSInteropItemDescriptor),
            .kind = MacWSInteropKindPasteboardArchive,
            .flags = MacWSInteropInlinePayload | MacWSInteropFromIOS,
            .generation = atomic_fetch_add_explicit(&MacWSProcessGeneration,
                1, memory_order_relaxed) + 1,
            .originID = MacWSProcessOriginID,
            .payloadLength = archive.length,
        };
        MacWSDigest(archive, descriptor.digest);
        xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(request, MACWS_INTEROP_KEY_OP,
                                  MACWS_INTEROP_OP_PUBLISH_PASTEBOARD);
        xpc_dictionary_set_data(request, MACWS_INTEROP_KEY_DESCRIPTOR,
                                &descriptor, sizeof(descriptor));
        xpc_dictionary_set_data(request, MACWS_INTEROP_KEY_PAYLOAD,
                                archive.bytes, archive.length);
        xpc_connection_send_message_with_reply(self.connection, request,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
            ^(xpc_object_t reply) {
                BOOL ok = reply && xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
                    xpc_dictionary_get_bool(reply, MACWS_INTEROP_KEY_OK);
                const char *message = ok ? NULL : xpc_dictionary_get_string(
                    reply, MACWS_INTEROP_KEY_MESSAGE);
                NSError *error = ok ? nil : MacWSError(22, message
                    ? [NSString stringWithUTF8String:message]
                    : @"macOS 未接受剪贴板数据");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self publishStatus:ok ? @"iPadOS 剪贴板已同步到 macOS"
                                           : error.localizedDescription
                                      connected:self.connection != nil];
                    if (completion) completion(ok, error);
                });
            });
    });
}

- (void)publishGeneralPasteboard {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self publishGeneralPasteboard];
        });
        return;
    }
    UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
    NSInteger snapshotChange = pasteboard.changeCount;
    if (self.pendingLocalPasteboardChange < 0)
        self.pendingLocalPasteboardChange = snapshotChange;
    NSMutableArray *pasteItems = [NSMutableArray array];
    for (NSDictionary *item in pasteboard.items)
        [pasteItems addObject:[item mutableCopy]];

    // UIKit producers are allowed to publish an abstract public.text or
    // public.plain-text representation. AppKit's NSPasteboardTypeString
    // consumers ask for public.utf8-plain-text. Preserve every original type,
    // but add that concrete UTF-8 representation to the same logical item.
    NSUInteger textItemIndex = NSNotFound;
    BOOL hasUTF8Text = NO;
    for (NSUInteger index = 0; index < pasteItems.count; index++) {
        NSDictionary *item = pasteItems[index];
        for (NSString *typeIdentifier in item) {
            if ([typeIdentifier isEqualToString:
                    UTTypeUTF8PlainText.identifier]) hasUTF8Text = YES;
            UTType *type = [UTType typeWithIdentifier:typeIdentifier];
            if (textItemIndex == NSNotFound &&
                [type conformsToType:UTTypeText]) textItemIndex = index;
        }
    }
    NSString *plainText = textItemIndex != NSNotFound && !hasUTF8Text
        ? pasteboard.string : nil;
    if (plainText) {
        NSMutableDictionary *textItem = pasteItems[textItemIndex];
        textItem[UTTypeUTF8PlainText.identifier] = plainText;
    }
    if (MacWSHostDiagnosticsEnabled()) {
        NSMutableArray<NSString *> *typeSummaries = [NSMutableArray array];
        for (NSDictionary *item in pasteItems)
            [typeSummaries addObject:[[item.allKeys
                sortedArrayUsingSelector:@selector(compare:)]
                componentsJoinedByString:@","]];
        MacWSLog(@"interop-local-publish change=%ld items=%lu types=%@ "
            "canonical-text=%@", (long)pasteboard.changeCount,
            (unsigned long)pasteItems.count,
            [typeSummaries componentsJoinedByString:@" | "],
            plainText ? @"added" : (hasUTF8Text ? @"present" : @"none"));
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray *items = [self archiveItemsForUIKitItems:pasteItems
                                              stagedURLs:nil error:&error];
        NSData *archive = items ? MacWSArchiveData(items, &error) : nil;
        if (!archive) {
            [self publishStatus:error.localizedDescription connected:self.isConnected];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.pendingLocalPasteboardChange == snapshotChange)
                    self.pendingLocalPasteboardChange = -1;
            });
            return;
        }
        [self sendArchiveData:archive completion:^(BOOL applied,
                                                   NSError *sendError) {
            (void)sendError;
            if (applied) {
                self.lastLocalPasteboardChange = snapshotChange;
                [NSUserDefaults.standardUserDefaults
                    setInteger:snapshotChange
                    forKey:MacWSObservedPasteboardChangeDefaultsKey];
            }
            if (self.pendingLocalPasteboardChange == snapshotChange)
                self.pendingLocalPasteboardChange = -1;
            MacWSDiagnosticLog(@"interop-local-publish-result change=%ld applied=%@ "
                "current=%ld pending=%ld", (long)snapshotChange,
                applied ? @"YES" : @"NO",
                (long)UIPasteboard.generalPasteboard.changeCount,
                (long)self.pendingLocalPasteboardChange);
            if (!applied && UIApplication.sharedApplication.applicationState ==
                    UIApplicationStateActive) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                              500 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                    [self localPasteboardChanged:nil];
                });
            }
        }];
    });
}

- (void)stageAndPublishFiles:(NSArray<NSURL *> *)urls
                  completion:(void (^)(NSArray<NSURL *> *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSArray *staged = nil, *paths = nil;
        if (!MacWSStageURLs(urls, &staged, &paths, &error)) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], error); });
            return;
        }
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *path in paths) [items addObject:@{
            MacWSArchiveRepresentationsKey: @[@{
                MacWSArchiveTypeKey: UTTypeFileURL.identifier,
                MacWSArchiveFilePathKey: path
            }]
        }];
        NSData *archive = MacWSArchiveData(items, &error);
        if (!archive) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], error); });
            return;
        }
        [self sendArchiveData:archive completion:^(BOOL applied, NSError *sendError) {
            completion(applied ? staged : @[], sendError);
        }];
    });
}

- (void)sendLoadedProviderSlots:(NSArray<NSMutableArray *> *)slots
                     completion:(void (^)(BOOL, NSError *))completion {
    NSMutableArray *archiveItems = [NSMutableArray array];
    NSUInteger totalRepresentations = 0;
    NSUInteger totalBytes = 0;
    for (NSMutableArray *slot in slots) {
        [slot sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                       NSDictionary *b) {
            return [a[@"order"] compare:b[@"order"]];
        }];
        NSMutableArray *representations = [NSMutableArray array];
        NSMutableSet<NSString *> *acceptedTypes = [NSMutableSet set];
        for (NSDictionary *loaded in slot) {
            if (totalRepresentations >= MACWS_INTEROP_MAX_REPRESENTATIONS)
                break;
            NSString *path = loaded[MacWSArchiveFilePathKey];
            NSData *data = loaded[MacWSArchiveDataKey];
            NSString *type = loaded[MacWSArchiveTypeKey];
            if (!type.length || [acceptedTypes containsObject:type]) continue;
            if (path) {
                if (!MacWSSharedTransferPath(path)) continue;
                [representations addObject:@{
                    MacWSArchiveTypeKey: type,
                    MacWSArchiveFilePathKey: path
                }];
            } else {
                if (!data || data.length >
                    MACWS_INTEROP_MAX_INLINE_BYTES - totalBytes) continue;
                totalBytes += data.length;
                [representations addObject:@{
                    MacWSArchiveTypeKey: type,
                    MacWSArchiveDataKey: data
                }];
            }
            [acceptedTypes addObject:type];
            totalRepresentations++;
        }
        if (representations.count) [archiveItems addObject:@{
            MacWSArchiveRepresentationsKey: representations
        }];
    }
    NSError *error = nil;
    // A successful drop must account for every requested item, including
    // providers which returned errors (not just providers which timed out).
    // A missing format must not silently turn a multi-file drop into a subset.
    BOOL complete = archiveItems.count == slots.count && slots.count > 0;
    NSData *archive = complete
        ? MacWSArchiveData(archiveItems, &error) : nil;
    if (!archive) {
        MacWSRemoveUnpublishedProviderFiles(slots);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, error ?: MacWSError(31,
                @"部分项目没有可用的拖放格式；没有交付部分文件"));
        });
        return;
    }
    [self sendArchiveData:archive completion:completion];
}

- (void)publishItemProviders:(NSArray<NSItemProvider *> *)providers
                  completion:(void (^)(BOOL, NSError *))completion {
    if (!providers.count) {
        completion(NO, MacWSError(30, @"拖放内容为空"));
        return;
    }
    if (providers.count > MACWS_INTEROP_MAX_ITEMS) {
        completion(NO, MacWSError(30, @"拖放项目过多，请分批传输"));
        return;
    }
    NSUInteger itemLimit = providers.count;
    NSMutableArray *slots = [NSMutableArray arrayWithCapacity:itemLimit];
    for (NSUInteger i = 0; i < itemLimit; i++)
        [slots addObject:[NSMutableArray array]];
    NSMutableArray<NSDictionary *> *jobs = [NSMutableArray array];
    NSUInteger scheduledRepresentations = 0;
    for (NSUInteger itemIndex = 0; itemIndex < itemLimit; itemIndex++) {
        NSItemProvider *provider = providers[itemIndex];
        NSArray<NSString *> *types = provider.registeredTypeIdentifiers;
        MacWSLog(@"interop-provider-input item=%lu name=%@ types=%@",
            (unsigned long)itemIndex, provider.suggestedName ?: @"(nil)",
            [types componentsJoinedByString:@","]);
        if (scheduledRepresentations < MACWS_INTEROP_MAX_REPRESENTATIONS &&
            [provider hasItemConformingToTypeIdentifier:UTTypeFileURL.identifier]) {
            [jobs addObject:@{
                @"provider": provider,
                @"item_index": @(itemIndex),
                @"order": @(-2),
                MacWSArchiveTypeKey: UTTypeFileURL.identifier,
                @"kind": @"file-url"
            }];
            scheduledRepresentations++;
        }
        NSString *materializationType = MacWSPreferredMaterializationType(types);
        UTType *materializationUniformType = materializationType.length
            ? [UTType typeWithIdentifier:materializationType] : nil;
        BOOL namedSingleImageDataFirst = provider.suggestedName.length &&
            types.count == 1 &&
            [materializationUniformType conformsToType:UTTypeImage] &&
            ![provider hasItemConformingToTypeIdentifier:
                UTTypeFileURL.identifier];
        if (namedSingleImageDataFirst &&
            scheduledRepresentations < MACWS_INTEROP_MAX_REPRESENTATIONS) {
            // Runtime-confirmed twice for Photos (MacWSHost.log
            // 1789909109.945 and 1789963595.607): its named, single-image
            // drag provider's generic loadItem endpoint returned a missing
            // /var/tmp/com.apple.DragUI.druid URL and invalidated the
            // one-shot endpoint before the later data request.  Notes' working
            // provider in the same log was unnamed and returned a real
            // callback-scoped container URL.  Consume the declared image data
            // first only for the observed Photos provider shape; keep Notes'
            // proven direct-item ordering unchanged.
            [jobs addObject:@{
                @"provider": provider,
                @"item_index": @(itemIndex),
                @"order": @(-3.5),
                MacWSArchiveTypeKey: materializationType,
                @"kind": @"primary-data",
                @"materialize_data": @YES
            }];
            scheduledRepresentations++;
        }
        if (materializationType &&
            scheduledRepresentations < MACWS_INTEROP_MAX_REPRESENTATIONS) {
            // Request the provider's primary payload while performDrop: still
            // owns the UIDropSession. Runtime-confirmed on 2026-09-10: Notes'
            // public.png endpoint was invalidated after the earlier in-place
            // and UIImage attempts, so the later data request received zero
            // bytes. loadItem preserves either its real callback-scoped URL
            // or concrete object for abstract and concrete UTIs alike.
            [jobs addObject:@{
                @"provider": provider,
                @"item_index": @(itemIndex),
                @"order": @(-3),
                MacWSArchiveTypeKey: materializationType,
                @"kind": @"direct-item"
            }];
            scheduledRepresentations++;
        }
        if (!namedSingleImageDataFirst && materializationType &&
            scheduledRepresentations < MACWS_INTEROP_MAX_REPRESENTATIONS) {
            // Keep the provider's declared data loader as a fallback when
            // loadItem returns an object that cannot be materialized.
            [jobs addObject:@{
                @"provider": provider,
                @"item_index": @(itemIndex),
                @"order": @(-2.5),
                MacWSArchiveTypeKey: materializationType,
                @"kind": @"primary-data",
                @"materialize_data": @YES
            }];
            scheduledRepresentations++;
        }
        if (materializationType &&
            scheduledRepresentations < MACWS_INTEROP_MAX_REPRESENTATIONS) {
            [jobs addObject:@{
                @"provider": provider,
                @"item_index": @(itemIndex),
                @"order": @(-1.75),
                MacWSArchiveTypeKey: materializationType,
                @"kind": @"in-place"
            }];
            scheduledRepresentations++;
        }
        if ([materializationUniformType conformsToType:UTTypeImage] &&
            scheduledRepresentations < MACWS_INTEROP_MAX_REPRESENTATIONS) {
            [jobs addObject:@{
                @"provider": provider,
                @"item_index": @(itemIndex),
                @"order": @(-1.5),
                MacWSArchiveTypeKey: materializationType,
                @"kind": @"image-object"
            }];
            scheduledRepresentations++;
        }
        if (materializationType &&
            scheduledRepresentations < MACWS_INTEROP_MAX_REPRESENTATIONS) {
            [jobs addObject:@{
                @"provider": provider,
                @"item_index": @(itemIndex),
                @"order": @(-1),
                MacWSArchiveTypeKey: materializationType,
                @"kind": @"materialize"
            }];
            scheduledRepresentations++;
        }
        NSUInteger typeLimit = MIN(types.count, MACWS_INTEROP_MAX_REPRESENTATIONS);
        for (NSUInteger typeIndex = 0; typeIndex < typeLimit; typeIndex++) {
            if (scheduledRepresentations >= MACWS_INTEROP_MAX_REPRESENTATIONS)
                break;
            NSString *type = types[typeIndex];
            // The file representation below is the authoritative form. A
            // second raw public.file-url representation would overwrite the
            // staged URL when NSPasteboardItem de-duplicates identical types.
            if (!type.length || [type isEqualToString:UTTypeFileURL.identifier])
                continue;
            if ([type isEqualToString:materializationType]) continue;
            [jobs addObject:@{
                @"provider": provider,
                @"item_index": @(itemIndex),
                @"order": @(typeIndex),
                MacWSArchiveTypeKey: type,
                @"kind": @"data",
                @"materialize_data": @([type isEqualToString:
                    materializationType])
            }];
            scheduledRepresentations++;
        }
    }
    if (!jobs.count) {
        completion(NO, MacWSError(31, @"没有可用的拖放格式"));
        return;
    }

    // NSItemProvider is allowed to call every representation loader on a
    // different queue. Starting all 128 at once can transiently materialize
    // gigabytes even though the final archive is capped at 64 MiB. Load one
    // representation at a time. A provider gets its own acquisition deadline;
    // a callback-scoped file copy must finish before any result is published.
    // this keeps peak retained payload bounded to the accepted archive plus
    // the single active provider result.
    dispatch_queue_t loadQueue = dispatch_queue_create(
        "com.macwsguide.host.interop-item-provider", DISPATCH_QUEUE_SERIAL);
    __block NSUInteger jobIndex = 0;
    __block NSUInteger acceptedInlineBytes = 0;
    __block BOOL finished = NO;
    NSObject *gate = [[NSObject alloc] init];
    __block BOOL callbackActive = NO;
    __block CFAbsoluteTime jobStarted = CFAbsoluteTimeGetCurrent();
    __block dispatch_source_t deadlineTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, loadQueue);
    __block void (^loadNext)(void) = nil;
    __block __weak void (^weakLoadNext)(void) = nil;
    loadNext = ^{
        if (finished) return;
        // Once one real file representation has been staged, avoid asking
        // that same short-lived provider for redundant formats. Runtime logs
        // show Notes invalidating its endpoint during those later loaders;
        // Finder only needs the staged public.file-url for this drag item.
        while (jobIndex < jobs.count) {
            NSDictionary *candidate = jobs[jobIndex];
            NSUInteger candidateIndex =
                [candidate[@"item_index"] unsignedIntegerValue];
            if (!MacWSSlotHasFileURL(slots[candidateIndex])) break;
            jobIndex++;
        }
        if (jobIndex >= jobs.count) {
            @synchronized (gate) { finished = YES; }
            dispatch_source_cancel(deadlineTimer);
            dispatch_source_set_event_handler(deadlineTimer, nil);
            deadlineTimer = nil;
            [self sendLoadedProviderSlots:slots completion:completion];
            loadNext = nil;
            return;
        }
        @synchronized (gate) {
            callbackActive = NO;
            jobStarted = CFAbsoluteTimeGetCurrent();
        }
        NSDictionary *job = jobs[jobIndex];
        NSItemProvider *provider = job[@"provider"];
        NSUInteger itemIndex = [job[@"item_index"] unsignedIntegerValue];
        NSString *type = job[MacWSArchiveTypeKey];
        NSString *kind = job[@"kind"];
        if ([kind isEqualToString:@"direct-item"]) {
            [provider loadItemForTypeIdentifier:type options:nil
                completionHandler:^(id item, NSError *providerError) {
                @synchronized (gate) {
                    if (finished) return;
                    callbackActive = YES;
                }
                // Keep every URL operation inside the provider callback: the
                // security extension and temporary file are not promised to
                // remain valid after this block returns.
                NSString *path = nil;
                NSError *stageError = nil;
                NSURL *url = providerError ? nil :
                    MacWSResolvedProviderFileURL(item);
                if (url) {
                    MacWSStageProviderURL(url, provider.suggestedName, type,
                                         itemIndex, &path, &stageError);
                } else if (!providerError &&
                           [item isKindOfClass:NSData.class]) {
                    MacWSStageProviderData(item, provider.suggestedName, type,
                                          itemIndex, &path, &stageError);
                } else if (!providerError &&
                           [item isKindOfClass:UIImage.class]) {
                    NSData *data = UIImagePNGRepresentation(item);
                    MacWSStageProviderData(data, provider.suggestedName,
                                          UTTypePNG.identifier, itemIndex,
                                          &path, &stageError);
                } else if (!providerError &&
                           [item isKindOfClass:NSString.class]) {
                    NSData *data = [item dataUsingEncoding:
                        NSUTF8StringEncoding];
                    MacWSStageProviderData(data, provider.suggestedName, type,
                                          itemIndex, &path, &stageError);
                }
                NSString *itemClass = item
                    ? NSStringFromClass([item class]) : @"(nil)";
                dispatch_async(loadQueue, ^{
                    if (finished) return;
                    if (path.length && !MacWSSlotHasFileURL(slots[itemIndex])) {
                        [slots[itemIndex] addObject:@{
                            @"order": job[@"order"],
                            MacWSArchiveTypeKey: UTTypeFileURL.identifier,
                            MacWSArchiveFilePathKey: path
                        }];
                    }
                    MacWSLog(@"interop-provider-load item=%lu kind=%@ type=%@ class=%@ source-url=%@ source-exists=%@ accepted=%@ error=%@",
                        (unsigned long)itemIndex, kind, type, itemClass,
                        url.path ?: @"(nil)",
                        url && [NSFileManager.defaultManager
                            fileExistsAtPath:url.path] ? @"YES" : @"NO",
                        path.length ? @"YES" : @"NO",
                        providerError ?: stageError ?: @"nil");
                    jobIndex++;
                    void (^next)(void) = weakLoadNext;
                    if (next) next();
                });
            }];
            return;
        }
        if ([kind isEqualToString:@"file-url"]) {
            [provider loadItemForTypeIdentifier:type options:nil
                completionHandler:^(id item, NSError *providerError) {
                @synchronized (gate) {
                    if (finished) return;
                    callbackActive = YES;
                }
                // Provider URLs can be temporary for only this callback.
                // Resolve and copy synchronously before returning to UIKit.
                NSURL *url = providerError ? nil :
                    MacWSResolvedProviderFileURL(item);
                NSString *path = nil;
                NSError *stageError = nil;
                if (url) MacWSStageProviderURL(url, provider.suggestedName,
                    type, itemIndex, &path, &stageError);
                dispatch_async(loadQueue, ^{
                    if (finished) return;
                    if (path.length) [slots[itemIndex] addObject:@{
                        @"order": job[@"order"],
                        MacWSArchiveTypeKey: type,
                        MacWSArchiveFilePathKey: path
                    }];
                    MacWSLog(@"interop-provider-load item=%lu kind=%@ type=%@ accepted=%@ error=%@",
                        (unsigned long)itemIndex, kind, type,
                        path.length ? @"YES" : @"NO",
                        providerError ?: stageError ?: @"nil");
                    jobIndex++;
                    void (^next)(void) = weakLoadNext;
                    if (next) next();
                });
            }];
            return;
        }
        if ([kind isEqualToString:@"in-place"]) {
            if (MacWSSlotHasFileURL(slots[itemIndex])) {
                jobIndex++;
                void (^next)(void) = weakLoadNext;
                if (next) next();
                return;
            }
            // Notes and Photos can vend an attachment whose ordinary
            // loadFileRepresentation path first tries to copy into a
            // provider-owned temporary directory. Runtime-confirmed in
            // MacWSHost.log at 1788881880.896: that intermediate copy failed
            // with NSItemProviderErrorDomain -1000 before Host received a URL.
            // Ask for the provider's supported in-place representation and
            // copy it synchronously into the shared MacWS import directory
            // while the callback's security scope is valid.
            [provider loadInPlaceFileRepresentationForTypeIdentifier:type
                completionHandler:^(NSURL *url, BOOL inPlace,
                                    NSError *providerError) {
                @synchronized (gate) {
                    if (finished) return;
                    callbackActive = YES;
                }
                NSString *path = nil;
                NSError *stageError = nil;
                if (!providerError && url) MacWSStageProviderURL(url,
                    provider.suggestedName, type, itemIndex, &path,
                    &stageError);
                dispatch_async(loadQueue, ^{
                    if (finished) return;
                    if (path.length && !MacWSSlotHasFileURL(slots[itemIndex])) {
                        [slots[itemIndex] addObject:@{
                            @"order": job[@"order"],
                            MacWSArchiveTypeKey: UTTypeFileURL.identifier,
                            MacWSArchiveFilePathKey: path
                        }];
                    }
                    MacWSLog(@"interop-provider-load item=%lu kind=%@ type=%@ in-place=%@ accepted=%@ error=%@",
                        (unsigned long)itemIndex, kind, type,
                        inPlace ? @"YES" : @"NO",
                        path.length ? @"YES" : @"NO",
                        providerError ?: stageError ?: @"nil");
                    jobIndex++;
                    void (^next)(void) = weakLoadNext;
                    if (next) next();
                });
            }];
            return;
        }
        if ([kind isEqualToString:@"image-object"]) {
            if (MacWSSlotHasFileURL(slots[itemIndex])) {
                jobIndex++;
                void (^next)(void) = weakLoadNext;
                if (next) next();
                return;
            }
            // An image object avoids the same temporary-file copy boundary
            // for inline Notes attachments. UIKit still asks the provider for
            // its declared image object; the bridge only serializes that real
            // object into the declared PNG representation.
            [provider loadObjectOfClass:UIImage.class
                completionHandler:^(id<NSItemProviderReading> object,
                                    NSError *providerError) {
                @synchronized (gate) {
                    if (finished) return;
                    callbackActive = YES;
                }
                UIImage *providerImage = [object isKindOfClass:UIImage.class]
                    ? (UIImage *)object : nil;
                NSData *data = providerImage
                    ? UIImagePNGRepresentation(providerImage) : nil;
                NSString *path = nil;
                NSError *stageError = nil;
                if (data.length <= MACWS_INTEROP_MAX_INLINE_BYTES)
                    MacWSStageProviderData(data, provider.suggestedName,
                        UTTypePNG.identifier, itemIndex, &path, &stageError);
                dispatch_async(loadQueue, ^{
                    if (finished) return;
                    if (path.length && !MacWSSlotHasFileURL(slots[itemIndex])) {
                        [slots[itemIndex] addObject:@{
                            @"order": job[@"order"],
                            MacWSArchiveTypeKey: UTTypeFileURL.identifier,
                            MacWSArchiveFilePathKey: path
                        }];
                    }
                    MacWSLog(@"interop-provider-load item=%lu kind=%@ type=%@ bytes=%lu accepted=%@ error=%@",
                        (unsigned long)itemIndex, kind, type,
                        (unsigned long)data.length,
                        path.length ? @"YES" : @"NO",
                        providerError ?: stageError ?: @"nil");
                    jobIndex++;
                    void (^next)(void) = weakLoadNext;
                    if (next) next();
                });
            }];
            return;
        }
        if ([kind isEqualToString:@"materialize"]) {
            if (MacWSSlotHasFileURL(slots[itemIndex])) {
                jobIndex++;
                void (^next)(void) = weakLoadNext;
                if (next) next();
                return;
            }
            [provider loadFileRepresentationForTypeIdentifier:type
                completionHandler:^(NSURL *url, NSError *providerError) {
                @synchronized (gate) {
                    if (finished) return;
                    callbackActive = YES;
                }
                // loadFileRepresentation's URL is explicitly callback-scoped.
                NSString *path = nil;
                NSError *stageError = nil;
                if (!providerError && url) MacWSStageProviderURL(url,
                    provider.suggestedName, type, itemIndex, &path,
                    &stageError);
                dispatch_async(loadQueue, ^{
                    if (finished) return;
                    if (path.length && !MacWSSlotHasFileURL(slots[itemIndex])) {
                        [slots[itemIndex] addObject:@{
                            @"order": job[@"order"],
                            MacWSArchiveTypeKey: UTTypeFileURL.identifier,
                            MacWSArchiveFilePathKey: path
                        }];
                    }
                    MacWSLog(@"interop-provider-load item=%lu kind=%@ type=%@ accepted=%@ error=%@",
                        (unsigned long)itemIndex, kind, type,
                        path.length ? @"YES" : @"NO",
                        providerError ?: stageError ?: @"nil");
                    jobIndex++;
                    void (^next)(void) = weakLoadNext;
                    if (next) next();
                });
            }];
            return;
        }
        if (acceptedInlineBytes >= MACWS_INTEROP_MAX_INLINE_BYTES) {
            jobIndex++;
            void (^next)(void) = weakLoadNext;
            if (next) next();
            return;
        }
        [provider loadDataRepresentationForTypeIdentifier:type
            completionHandler:^(NSData *data, NSError *providerError) {
            @synchronized (gate) {
                if (finished) return;
                callbackActive = YES;
            }
            dispatch_async(loadQueue, ^{
                if (finished) return;
                if (!providerError && data && data.length <=
                    MACWS_INTEROP_MAX_INLINE_BYTES - acceptedInlineBytes) {
                    acceptedInlineBytes += data.length;
                    [slots[itemIndex] addObject:@{
                        @"order": job[@"order"],
                        MacWSArchiveTypeKey: type,
                        MacWSArchiveDataKey: data
                    }];
                    if ([job[@"materialize_data"] boolValue] &&
                        !MacWSSlotHasFileURL(slots[itemIndex])) {
                        NSString *path = nil;
                        NSError *stageError = nil;
                        if (MacWSStageProviderData(data, provider.suggestedName,
                                type, itemIndex, &path, &stageError)) {
                            [slots[itemIndex] addObject:@{
                                @"order": @(-1),
                                MacWSArchiveTypeKey: UTTypeFileURL.identifier,
                                MacWSArchiveFilePathKey: path
                            }];
                        } else if (stageError) {
                            MacWSLog(@"interop-provider-stage-data item=%lu type=%@ error=%@",
                                (unsigned long)itemIndex, type, stageError);
                        }
                    }
                }
                MacWSLog(@"interop-provider-load item=%lu kind=%@ type=%@ bytes=%lu accepted=%@ error=%@",
                    (unsigned long)itemIndex, kind, type,
                    (unsigned long)data.length,
                    (!providerError && data.length) ? @"YES" : @"NO",
                    providerError ?: @"nil");
                jobIndex++;
                void (^next)(void) = weakLoadNext;
                if (next) next();
            });
        }];
    };
    weakLoadNext = loadNext;
    dispatch_source_set_timer(deadlineTimer,
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
        5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(deadlineTimer, ^{
        @synchronized (gate) {
            if (finished || callbackActive ||
                CFAbsoluteTimeGetCurrent() - jobStarted < 90.0) return;
            finished = YES;
        }
        dispatch_source_cancel(deadlineTimer);
        dispatch_source_set_event_handler(deadlineTimer, nil);
        deadlineTimer = nil;
        loadNext = nil;
        // Never report a partially acquired multi-file drop as success. No
        // active copy can race this cleanup: callback ownership is gated.
        MacWSRemoveUnpublishedProviderFiles(slots);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NO, MacWSError(32, @"文件提供器等待超时，请下载文件后重试；没有交付部分文件"));
        });
    });
    dispatch_resume(deadlineTimer);
    // Initiate the primary representation before UIDropInteraction returns
    // from performDrop:. Subsequent work stays serialized on loadQueue, but
    // this first request is now inside the source endpoint's owned lifetime.
    loadNext();
}

- (NSData *)archivePayloadFromMessage:(xpc_object_t)message
                           descriptor:(MacWSInteropItemDescriptor *)outDescriptor {
    size_t descriptorSize = 0;
    const void *bytes = xpc_dictionary_get_data(message,
        MACWS_INTEROP_KEY_DESCRIPTOR, &descriptorSize);
    if (!bytes || descriptorSize != sizeof(MacWSInteropItemDescriptor)) return nil;
    MacWSInteropItemDescriptor descriptor;
    memcpy(&descriptor, bytes, sizeof(descriptor));
    if (!MacWSInteropItemDescriptorIsValid(&descriptor, descriptorSize) ||
        descriptor.kind != MacWSInteropKindPasteboardArchive ||
        (descriptor.flags & MacWSInteropFromMacOS) == 0) return nil;
    size_t payloadSize = 0;
    const void *payloadBytes = xpc_dictionary_get_data(message,
        MACWS_INTEROP_KEY_PAYLOAD, &payloadSize);
    if (!payloadBytes || payloadSize != descriptor.payloadLength) return nil;
    NSData *payload = [NSData dataWithBytes:payloadBytes length:payloadSize];
    uint8_t digest[16];
    MacWSDigest(payload, digest);
    if (memcmp(digest, descriptor.digest, sizeof(digest)) != 0) return nil;
    if (outDescriptor) *outDescriptor = descriptor;
    return payload;
}

- (NSArray<NSItemProvider *> *)itemProvidersForArchiveData:(NSData *)archive
                                                stagedURLs:
                                                    (NSArray<NSURL *> * _Nullable
                                                     * _Nullable)outURLs
                                                     error:(NSError **)error {
    NSArray *items = MacWSValidatedArchiveItems(archive, error);
    if (!items) return @[];
    NSMutableArray *providers = [NSMutableArray array];
    NSMutableArray<NSURL *> *exportedURLs = [NSMutableArray array];
    for (NSDictionary *item in items) {
        NSURL *primaryURL = nil;
        for (NSDictionary *representation in
                item[MacWSArchiveRepresentationsKey]) {
            NSString *path = representation[MacWSArchiveFilePathKey];
            if (!path) continue;
            NSString *hostPath = [MacWSRootFSHostPrefix
                stringByAppendingString:path.stringByStandardizingPath];
            if ([NSFileManager.defaultManager fileExistsAtPath:hostPath]) {
                primaryURL = [NSURL fileURLWithPath:hostPath];
                break;
            }
        }
        NSItemProvider *provider = nil;
        NSUInteger registered = 0;
        if (primaryURL) {
            NSError *stageError = nil;
            NSURL *providerURL = MacWSStageDragProviderURL(primaryURL,
                                                           &stageError);
            provider = providerURL ? MacWSFileDragItemProvider(
                providerURL, primaryURL.lastPathComponent) : nil;
            if (provider) {
                registered = provider.registeredTypeIdentifiers.count;
                [exportedURLs addObject:providerURL];
                MacWSLog(@"interop-provider-container-stage source=%@ staged=%@ "
                    "mode=file types=%@", primaryURL.path, providerURL.path,
                    [provider.registeredTypeIdentifiers
                        componentsJoinedByString:@","]);
            } else {
                // Keep a readable diagnostic representation if container
                // resolution fails, but do not re-introduce a raw file URL.
                provider = MacWSFileDragItemProvider(
                    primaryURL, primaryURL.lastPathComponent);
                registered = provider.registeredTypeIdentifiers.count;
                MacWSLog(@"interop-provider-container-stage source=%@ failed=%@",
                    primaryURL.path, stageError ?: @"unknown");
            }
        }
        if (!provider) provider = [NSItemProvider new];
        for (NSDictionary *representation in item[MacWSArchiveRepresentationsKey]) {
            NSString *type = representation[MacWSArchiveTypeKey];
            NSString *path = representation[MacWSArchiveFilePathKey];
            if (path) {
                // A primary file is represented only by the staged iOS URL.
                // Never re-register the chroot URL or expose public.file-url.
                if (primaryURL) continue;
                NSString *hostPath = [MacWSRootFSHostPrefix
                    stringByAppendingString:path.stringByStandardizingPath];
                NSURL *url = [NSURL fileURLWithPath:hostPath];
                if (![NSFileManager.defaultManager fileExistsAtPath:hostPath])
                    continue;
                if (![provider.registeredTypeIdentifiers containsObject:type]) {
                    [provider registerFileRepresentationForTypeIdentifier:type
                        fileOptions:0
                        visibility:NSItemProviderRepresentationVisibilityAll
                        loadHandler:^NSProgress *(void (^handler)(NSURL *, BOOL,
                                                                  NSError *)) {
                            MacWSLog(@"interop-provider-file-request type=%@ file=%@",
                                type, url.lastPathComponent);
                            handler(url, NO, nil);
                            return nil;
                        }];
                }
            } else {
                // A Finder file must stay file-backed through the drop. In
                // particular, publishing its inline text flavor lets Files
                // choose that representation and name the result "text".
                // Clipboard-only items have no primary URL and retain every
                // original data representation below.
                if (primaryURL) continue;
                if ([type hasPrefix:@"com.apple.finder."] ||
                    [type isEqualToString:UTTypeFileURL.identifier] ||
                    [type isEqualToString:UTTypeURL.identifier]) continue;
                NSData *data = representation[MacWSArchiveDataKey];
                if (![provider.registeredTypeIdentifiers containsObject:type]) {
                    [provider registerDataRepresentationForTypeIdentifier:type
                        visibility:NSItemProviderRepresentationVisibilityAll
                        loadHandler:^NSProgress *(void (^handler)(NSData *, NSError *)) {
                            MacWSLog(@"interop-provider-data-request type=%@ bytes=%lu",
                                type, (unsigned long)data.length);
                            handler(data, nil);
                            return nil;
                        }];
                }
            }
            registered++;
        }
        if (registered) {
            BOOL item = [provider hasRepresentationConformingToTypeIdentifier:
                UTTypeItem.identifier fileOptions:0];
            BOOL data = [provider hasRepresentationConformingToTypeIdentifier:
                UTTypeData.identifier fileOptions:0];
            BOOL fileURL = [provider hasRepresentationConformingToTypeIdentifier:
                UTTypeFileURL.identifier fileOptions:0];
            BOOL content = [provider hasRepresentationConformingToTypeIdentifier:
                UTTypeContent.identifier fileOptions:0];
            BOOL directory = [provider hasRepresentationConformingToTypeIdentifier:
                UTTypeDirectory.identifier fileOptions:0];
            MacWSLog(@"interop-provider-output name=%@ types=%@ conforms="
                "item:%@ data:%@ file-url:%@ content:%@ directory:%@",
                provider.suggestedName ?: @"(nil)",
                [provider.registeredTypeIdentifiers componentsJoinedByString:@","],
                item ? @"YES" : @"NO", data ? @"YES" : @"NO",
                fileURL ? @"YES" : @"NO", content ? @"YES" : @"NO",
                directory ? @"YES" : @"NO");
            [providers addObject:provider];
        }
    }
    NSArray<NSURL *> *urls = [exportedURLs copy];
    if (outURLs) *outURLs = urls;
    if (urls.count && self.delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate interopClient:self receivedMacOSFilesAtURLs:urls];
        });
    }
    return providers;
}

- (xpc_object_t)sendSynchronousRequest:(xpc_object_t)request
                       timeoutSeconds:(NSTimeInterval)timeout {
    __block xpc_connection_t connection = nil;
    dispatch_sync(self.queue, ^{
        if ([self ensureConnection]) connection = self.connection;
    });
    if (!connection) return nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block xpc_object_t response = nil;
    xpc_connection_send_message_with_reply(connection, request,
        dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
        ^(xpc_object_t reply) {
            response = reply;
            dispatch_semaphore_signal(semaphore);
        });
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(timeout * NSEC_PER_SEC))) != 0) return nil;
    return response;
}

- (uint64_t)macOSDragPasteboardChangeCount {
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_INTEROP_KEY_OP,
                              MACWS_INTEROP_OP_SNAPSHOT_DRAG_PASTEBOARD);
    xpc_dictionary_set_uint64(request, MACWS_INTEROP_KEY_WAIT_MILLISECONDS, 0);
    xpc_object_t reply = [self sendSynchronousRequest:request timeoutSeconds:0.4];
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) return 0;
    return xpc_dictionary_get_uint64(reply, MACWS_INTEROP_KEY_CHANGE_COUNT);
}

- (NSArray<NSItemProvider *> *)macOSDragItemProvidersAfterChangeCount:
    (uint64_t)changeCount waitMilliseconds:(uint64_t)waitMilliseconds {
    return [self macOSDragItemProvidersAfterChangeCount:changeCount
                                       waitMilliseconds:waitMilliseconds
                                             stagedURLs:nil];
}

- (NSArray<NSItemProvider *> *)macOSDragItemProvidersAfterChangeCount:
    (uint64_t)changeCount waitMilliseconds:(uint64_t)waitMilliseconds
    stagedURLs:(NSArray<NSURL *> * _Nullable * _Nullable)stagedURLs {
    if (stagedURLs) *stagedURLs = @[];
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, MACWS_INTEROP_KEY_OP,
                              MACWS_INTEROP_OP_SNAPSHOT_DRAG_PASTEBOARD);
    xpc_dictionary_set_uint64(request, MACWS_INTEROP_KEY_AFTER_CHANGE_COUNT,
                              changeCount);
    xpc_dictionary_set_uint64(request, MACWS_INTEROP_KEY_WAIT_MILLISECONDS,
                              MIN(waitMilliseconds, 600));
    xpc_object_t reply = [self sendSynchronousRequest:request
        timeoutSeconds:MIN(waitMilliseconds, 600) / 1000.0 + 0.5];
    MacWSInteropItemDescriptor descriptor;
    NSData *archive = reply ? [self archivePayloadFromMessage:reply
                                                   descriptor:&descriptor] : nil;
    NSError *error = nil;
    return archive ? [self itemProvidersForArchiveData:archive
                                            stagedURLs:stagedURLs
                                                 error:&error] : @[];
}

- (NSItemProvider *)dragItemProviderForStagedURL:(NSURL *)url {
    return MacWSFileDragItemProvider(url, url.lastPathComponent);
}

- (void)handleEvent:(xpc_object_t)event {
    if (event == XPC_ERROR_CONNECTION_INVALID ||
        event == XPC_ERROR_CONNECTION_INTERRUPTED) {
        xpc_connection_t connection = self.connection;
        self.connection = nil;
        if (connection) xpc_connection_cancel(connection);
        [self publishStatus:@"macOS 互操作服务连接中断" connected:NO];
        return;
    }
    if (!event || xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
    const char *eventName = xpc_dictionary_get_string(event,
                                                       MACWS_INTEROP_KEY_EVENT);
    if (!eventName) return;
    if (strcmp(eventName, MACWS_INTEROP_EVENT_READY) == 0) {
        uint64_t version = xpc_dictionary_get_uint64(event,
            MACWS_INTEROP_KEY_PROTOCOL_VERSION);
        if (version != MACWS_INTEROP_VERSION) {
            [self publishStatus:@"iOS/macOS 互操作协议版本不匹配" connected:NO];
            return;
        }
        [self publishStatus:@"iOS/macOS 多格式剪贴板与文件桥已连接"
                  connected:YES];
        [self sendSubscription];
    } else if (strcmp(eventName, MACWS_INTEROP_EVENT_PASTEBOARD) == 0) {
        [self applyPasteboardArchiveEvent:event];
    } else if (strcmp(eventName, MACWS_INTEROP_EVENT_CLIPBOARD) == 0) {
        [self applyLegacyClipboardEvent:event];
    } else if (strcmp(eventName, MACWS_INTEROP_EVENT_FILES_READY) == 0) {
        [self applyLegacyFilesEvent:event];
    } else if (strcmp(eventName, MACWS_INTEROP_EVENT_ERROR) == 0) {
        const char *message = xpc_dictionary_get_string(event,
            MACWS_INTEROP_KEY_MESSAGE);
        [self publishStatus:message ? [NSString stringWithUTF8String:message]
                                    : @"iOS/macOS 互操作服务错误"
                  connected:NO];
    }
}

- (void)applyPasteboardArchiveEvent:(xpc_object_t)event {
    MacWSInteropItemDescriptor descriptor;
    NSData *archive = [self archivePayloadFromMessage:event descriptor:&descriptor];
    if (!archive || descriptor.originID == MacWSProcessOriginID) return;
    NSError *error = nil;
    NSArray *items = MacWSValidatedArchiveItems(archive, &error);
    if (!items) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (descriptor.originID == MacWSLastRemoteOrigin &&
            descriptor.generation <= MacWSLastRemoteGeneration) return;
        MacWSInteropClient *publisher = MacWSClipboardPublisher;
        NSInteger currentLocalChange =
            UIPasteboard.generalPasteboard.changeCount;
        NSInteger lastObservedLocalChange = publisher
            ? publisher.lastLocalPasteboardChange
            : self.lastLocalPasteboardChange;
        if (!MacWSApplyingRemotePasteboard &&
            ((publisher && publisher.pendingLocalPasteboardChange >= 0) ||
             currentLocalChange != lastObservedLocalChange)) {
            // Runtime boundary: after copying in another iPadOS app, the
            // global change count advances while this process is suspended.
            // A queued/stale macOS event must not overwrite that newer local
            // value before UIApplicationDidBecomeActive publishes it.
            MacWSLog(@"interop-remote-deferred reason=newer-local change=%ld "
                "last=%ld pending=%ld remote-origin=%llu remote-generation=%llu",
                (long)currentLocalChange, (long)lastObservedLocalChange,
                (long)(publisher ? publisher.pendingLocalPasteboardChange : -1),
                (unsigned long long)descriptor.originID,
                (unsigned long long)descriptor.generation);
            if (publisher) [publisher localPasteboardChanged:nil];
            return;
        }
        NSMutableArray *pasteboardItems = [NSMutableArray array];
        NSMutableArray *fileURLs = [NSMutableArray array];
        NSMutableArray<NSString *> *typeSummaries = [NSMutableArray array];
        for (NSDictionary *item in items) {
            NSMutableDictionary *values = [NSMutableDictionary dictionary];
            for (NSDictionary *representation in
                    item[MacWSArchiveRepresentationsKey]) {
                NSString *type = representation[MacWSArchiveTypeKey];
                NSString *path = representation[MacWSArchiveFilePathKey];
                if (path) {
                    NSString *hostPath = [MacWSRootFSHostPrefix
                        stringByAppendingString:path.stringByStandardizingPath];
                    if ([NSFileManager.defaultManager fileExistsAtPath:hostPath]) {
                        NSURL *url = [NSURL fileURLWithPath:hostPath];
                        values[type] = url;
                        [fileURLs addObject:url];
                    }
                } else {
                    values[type] = representation[MacWSArchiveDataKey];
                }
            }
            if (values.count) {
                [pasteboardItems addObject:values];
                [typeSummaries addObject:[[values.allKeys
                    sortedArrayUsingSelector:@selector(compare:)]
                    componentsJoinedByString:@","]];
            }
        }
        if (!pasteboardItems.count) return;
        MacWSLastRemoteOrigin = descriptor.originID;
        MacWSLastRemoteGeneration = descriptor.generation;
        MacWSApplyingRemotePasteboard = YES;
        UIPasteboard.generalPasteboard.items = pasteboardItems;
        self.lastLocalPasteboardChange = UIPasteboard.generalPasteboard.changeCount;
        self.pendingLocalPasteboardChange = -1;
        MacWSClipboardPublisher.lastLocalPasteboardChange =
            self.lastLocalPasteboardChange;
        MacWSClipboardPublisher.pendingLocalPasteboardChange = -1;
        [NSUserDefaults.standardUserDefaults
            setInteger:self.lastLocalPasteboardChange
            forKey:MacWSObservedPasteboardChangeDefaultsKey];
        self.localPublishSerial++;
        MacWSApplyingRemotePasteboard = NO;
        MacWSLog(@"interop-remote-applied change=%ld items=%lu files=%lu "
            "types=%@ origin=%llu generation=%llu",
            (long)self.lastLocalPasteboardChange,
            (unsigned long)pasteboardItems.count,
            (unsigned long)fileURLs.count,
            [typeSummaries componentsJoinedByString:@" | "],
            (unsigned long long)descriptor.originID,
            (unsigned long long)descriptor.generation);
        if (fileURLs.count)
            [self.delegate interopClient:self receivedMacOSFilesAtURLs:fileURLs];
        [self publishStatus:[NSString stringWithFormat:
            @"已接收 macOS 剪贴板：%lu 项、多格式",
            (unsigned long)pasteboardItems.count] connected:YES];
    });
}

- (void)applyLegacyClipboardEvent:(xpc_object_t)event {
    size_t descriptorSize = 0;
    const void *descriptorBytes = xpc_dictionary_get_data(event,
        MACWS_INTEROP_KEY_DESCRIPTOR, &descriptorSize);
    if (!descriptorBytes || descriptorSize != sizeof(MacWSInteropItemDescriptor))
        return;
    MacWSInteropItemDescriptor descriptor;
    memcpy(&descriptor, descriptorBytes, sizeof(descriptor));
    if (!MacWSInteropItemDescriptorIsValid(&descriptor, descriptorSize) ||
        descriptor.originID == MacWSProcessOriginID ||
        (descriptor.flags & MacWSInteropFromMacOS) == 0) return;
    size_t payloadSize = 0;
    const void *payloadBytes = xpc_dictionary_get_data(event,
        MACWS_INTEROP_KEY_PAYLOAD, &payloadSize);
    if (!payloadBytes || payloadSize != descriptor.payloadLength) return;
    NSData *payload = [NSData dataWithBytes:payloadBytes length:payloadSize];
    uint8_t digest[16];
    MacWSDigest(payload, digest);
    if (memcmp(digest, descriptor.digest, sizeof(digest))) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (descriptor.originID == MacWSLastRemoteOrigin &&
            descriptor.generation <= MacWSLastRemoteGeneration) return;
        MacWSApplyingRemotePasteboard = YES;
        if (descriptor.kind == MacWSInteropKindUTF8Text)
            UIPasteboard.generalPasteboard.string = [[NSString alloc]
                initWithData:payload encoding:NSUTF8StringEncoding];
        else if (descriptor.kind == MacWSInteropKindPNG)
            [UIPasteboard.generalPasteboard setData:payload
                                 forPasteboardType:UTTypePNG.identifier];
        else if (descriptor.kind == MacWSInteropKindJPEG)
            [UIPasteboard.generalPasteboard setData:payload
                                 forPasteboardType:UTTypeJPEG.identifier];
        MacWSLastRemoteOrigin = descriptor.originID;
        MacWSLastRemoteGeneration = descriptor.generation;
        self.lastLocalPasteboardChange = UIPasteboard.generalPasteboard.changeCount;
        MacWSClipboardPublisher.lastLocalPasteboardChange =
            self.lastLocalPasteboardChange;
        self.localPublishSerial++;
        MacWSApplyingRemotePasteboard = NO;
    });
}

- (void)applyLegacyFilesEvent:(xpc_object_t)event {
    xpc_object_t items = xpc_dictionary_get_value(event, MACWS_INTEROP_KEY_ITEMS);
    if (!items || xpc_get_type(items) != XPC_TYPE_ARRAY) return;
    NSMutableArray *urls = [NSMutableArray array];
    xpc_array_apply(items, ^bool(size_t index, xpc_object_t value) {
        (void)index;
        if (urls.count >= MACWS_INTEROP_MAX_ITEMS ||
            xpc_get_type(value) != XPC_TYPE_STRING) return true;
        const char *pathBytes = xpc_string_get_string_ptr(value);
        NSString *path = pathBytes ? [NSString stringWithUTF8String:pathBytes] : nil;
        if (MacWSSharedTransferPath(path)) {
            NSString *hostPath = [MacWSRootFSHostPrefix
                stringByAppendingString:path.stringByStandardizingPath];
            if ([NSFileManager.defaultManager fileExistsAtPath:hostPath])
                [urls addObject:[NSURL fileURLWithPath:hostPath]];
        }
        return true;
    });
    if (!urls.count) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        MacWSApplyingRemotePasteboard = YES;
        UIPasteboard.generalPasteboard.URLs = urls;
        self.lastLocalPasteboardChange = UIPasteboard.generalPasteboard.changeCount;
        MacWSClipboardPublisher.lastLocalPasteboardChange =
            self.lastLocalPasteboardChange;
        self.localPublishSerial++;
        MacWSApplyingRemotePasteboard = NO;
        [self.delegate interopClient:self receivedMacOSFilesAtURLs:urls];
    });
}

- (void)invalidate {
    xpc_connection_t connection = self.connection;
    self.connection = nil;
    self.connected = NO;
    if (MacWSClipboardPublisher == self) MacWSClipboardPublisher = nil;
    if (connection) xpc_connection_cancel(connection);
}

@end
