#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static BOOL MacWSInterestingName(const char *name) {
    if (!name) return NO;
    NSString *value = [NSString stringWithUTF8String:name].lowercaseString;
    return [value containsString:@"occl"] ||
        [value containsString:@"visib"] ||
        [value containsString:@"foreground"] ||
        [value containsString:@"background"] ||
        [value containsString:@"activation"] ||
        [value containsString:@"settings"];
}

static void MacWSDumpClass(Class cls) {
    if (!cls) return;
    printf("CLASS %s\n", class_getName(cls));
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int index = 0; index < count; index++) {
        const char *name = sel_getName(method_getName(methods[index]));
        if (MacWSInterestingName(name))
            printf("  METHOD %s %s\n", name,
                   method_getTypeEncoding(methods[index]));
    }
    free(methods);
    Ivar *ivars = class_copyIvarList(cls, &count);
    for (unsigned int index = 0; index < count; index++) {
        const char *name = ivar_getName(ivars[index]);
        if (MacWSInterestingName(name))
            printf("  IVAR %s %s +0x%lx\n", name,
                   ivar_getTypeEncoding(ivars[index]),
                   (unsigned long)ivar_getOffset(ivars[index]));
    }
    free(ivars);
    for (NSString *selectorName in @[@"_effectiveSettings", @"isOccluded",
                                      @"isForeground", @"isBackgrounded"]) {
        Method method = class_getInstanceMethod(cls,
            NSSelectorFromString(selectorName));
        if (!method) continue;
        IMP implementation = method_getImplementation(method);
        Dl_info info = {0};
        dladdr((const void *)implementation, &info);
        const uint8_t *bytes = (const uint8_t *)implementation;
        printf("  RE %s IMP=%p image=%s offset=0x%lx bytes=",
               selectorName.UTF8String, implementation,
               info.dli_fname ?: "?",
               info.dli_fbase ? (unsigned long)((uintptr_t)implementation -
                   (uintptr_t)info.dli_fbase) : 0ul);
        for (unsigned int index = 0; index < 32; index++)
            printf("%02x", bytes[index]);
        printf("\n");
    }
}

int main(void) {
    @autoreleasepool {
        NSString *const *notification = (NSString *const *)dlsym(
            RTLD_DEFAULT, "_UIApplicationSceneOcclusionChangedNotification");
        printf("NOTIFICATION %s\n", notification && *notification
            ? (*notification).UTF8String : "missing");
        NSArray<NSString *> *names = @[
            @"UIScene", @"UIWindowScene", @"FBSSceneSettings",
            @"FBSMutableSceneSettings", @"UIApplicationSceneSettings",
            @"UIApplicationSceneClientSettings",
            @"_UIWindowSceneOcclusionSettingsDiffAction"
        ];
        for (NSString *name in names) MacWSDumpClass(NSClassFromString(name));

        int count = objc_getClassList(NULL, 0);
        Class __unsafe_unretained *classes =
            (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
        count = objc_getClassList(classes, count);
        for (int index = 0; index < count; index++) {
            const char *className = class_getName(classes[index]);
            if (className && strstr(className, "Scene") &&
                (strstr(className, "Occl") || strstr(className, "Settings")))
                MacWSDumpClass(classes[index]);
        }
        free(classes);
    }
    return 0;
}
