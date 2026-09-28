// Read-only Objective-C runtime inventory for AppKit's window-tab classes.
// Build for macOS and invoke inside the chroot.  This deliberately creates no
// NSApplication or NSWindow: it only reports the selectors and implementation
// bytes exported by the exact AppKit image present on the target rootfs.
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void Deadline(int signalNumber) {
    (void)signalNumber;
    static const char message[] = "exercise-timeout\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void PrintMatchingMethods(Class cls) {
    if (!cls) return;
    for (Class cursor = cls; cursor; cursor = class_getSuperclass(cursor)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cursor, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *name = sel_getName(method_getName(methods[index]));
            if (!name || (!strcasestr(name, "tab") &&
                          !strcasestr(name, "stack") &&
                          strcmp(name, "windows") != 0 &&
                          strcmp(name, "window") != 0))
                continue;
            void *implementation = ptrauth_strip(
                method_getImplementation(methods[index]),
                ptrauth_key_function_pointer);
            Dl_info image = {0};
            dladdr(implementation, &image);
            fprintf(stdout,
                    "class=%s selector=%s types=%s image=%s offset=%#llx bytes=",
                    class_getName(cursor), name,
                    method_getTypeEncoding(methods[index]) ?: "<unknown>",
                    image.dli_fname ?: "<unknown>",
                    image.dli_fbase
                        ? (unsigned long long)((uintptr_t)implementation -
                                              (uintptr_t)image.dli_fbase)
                        : 0);
            const unsigned char *bytes = implementation;
            for (size_t byte = 0; byte < 64; byte++)
                fprintf(stdout, "%02x", bytes[byte]);
            fputc('\n', stdout);
            uint32_t firstInstruction = 0;
            memcpy(&firstInstruction, bytes, sizeof(firstInstruction));
            if ((firstInstruction & 0x7c000000u) == 0x14000000u) {
                int32_t displacement =
                    ((int32_t)(firstInstruction << 6) >> 6) * 4;
                const unsigned char *target = bytes + displacement;
                fprintf(stdout,
                        "branch-target class=%s selector=%s address=%p bytes=",
                        class_getName(cursor), name, target);
                for (size_t byte = 0; byte < 128; byte++)
                    fprintf(stdout, "%02x", target[byte]);
                fputc('\n', stdout);
            }
        }
        free(methods);
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 3 && (strcmp(argv[1], "--exercise") == 0 ||
                          strcmp(argv[1], "--tab-pair") == 0)) {
            signal(SIGALRM, Deadline);
            alarm(5);
            [NSApplication sharedApplication];
            NSWindow *window = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(0, 0, 640, 480)
                          styleMask:NSWindowStyleMaskTitled |
                                    NSWindowStyleMaskResizable
                            backing:NSBackingStoreBuffered
                              defer:NO];
            if (strcmp(argv[1], "--tab-pair") == 0) {
                NSWindow *peer = [[NSWindow alloc]
                    initWithContentRect:NSMakeRect(40, 40, 640, 480)
                              styleMask:NSWindowStyleMaskTitled |
                                        NSWindowStyleMaskResizable
                                backing:NSBackingStoreBuffered
                                  defer:NO];
                fprintf(stdout, "pair-add-before first=%p peer=%p\n",
                        window, peer);
                fflush(stdout);
                [window addTabbedWindow:peer ordered:NSWindowAbove];
                fprintf(stdout, "pair-add-after\n");
                fflush(stdout);
            }
            SEL selector = sel_registerName(argv[2]);
            fprintf(stdout,
                    "exercise-before selector=%s responds=%d window=%p\n",
                    argv[2], [window respondsToSelector:selector], window);
            fflush(stdout);
            if (![window respondsToSelector:selector]) return 2;
            if (!strcmp(argv[2], "isTabbed") ||
                !strcmp(argv[2], "_isTabbedWithOtherWindows")) {
                BOOL result = ((BOOL (*)(id, SEL))objc_msgSend)(window,
                                                               selector);
                fprintf(stdout, "exercise-after selector=%s bool=%d\n",
                        argv[2], result);
            } else {
                id result = ((id (*)(id, SEL))objc_msgSend)(window, selector);
                fprintf(stdout,
                        "exercise-after selector=%s object=%p class=%s\n",
                        argv[2], result,
                        result ? object_getClassName(result) : "<nil>");
                if (result && [result respondsToSelector:@selector(windows)])
                    fprintf(stdout, "exercise-windows count=%lu\n",
                            (unsigned long)[[result windows] count]);
            }
            fflush(stdout);
            return 0;
        }
        const char *classNames[] = {
            "NSWindow",
            "NSWindowTabGroup",
            "NSWindowStackController",
        };
        for (size_t index = 0;
             index < sizeof(classNames) / sizeof(classNames[0]); index++) {
            Class cls = objc_getClass(classNames[index]);
            fprintf(stdout, "runtime-class name=%s present=%d\n",
                    classNames[index], cls != Nil);
            PrintMatchingMethods(cls);
        }
    }
    return 0;
}
