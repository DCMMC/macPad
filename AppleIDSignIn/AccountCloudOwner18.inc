// Original AIDA loader/owner/authentication preserved. Only the fixed cloud
// bundle's location changes to the pane's allowed executable directory.
#include <os/log.h>
static id (*owner18Bundles)(id,SEL);
static NSString *const owner18Source=@"/System/Library/Accounts/ServiceOwners/AACloudServiceOwner.bundle";
static NSString *const owner18Embedded=@"/System/Library/ExtensionKit/Extensions/AppleIDSettings.appex/Contents/Frameworks/AACloudServiceOwner.bundle";
static id owner18RoutedBundles(id receiver,SEL selector) {
 id original=owner18Bundles(receiver,selector);
 BOOL set=[original isKindOfClass:NSSet.class];
 if(!set&&![original isKindOfClass:NSArray.class])return original;
 NSMutableArray *result=[NSMutableArray arrayWithCapacity:[original count]];
 for(NSBundle *bundle in original) {
  if([bundle.bundlePath isEqualToString:owner18Source]) {
   NSBundle *copy=[NSBundle bundleWithPath:owner18Embedded];
   if(copy && [copy.bundleIdentifier isEqualToString:bundle.bundleIdentifier]) [result addObject:copy];
   else [result addObject:bundle];
  } else [result addObject:bundle];
 }
 return set?(id)[NSSet setWithArray:result]:(id)[NSArray arrayWithArray:result];
}
static void installCloudOwner18(void) {
 Class manager=NSClassFromString(@"AIDAServiceOwnersManager");
 if(!manager) {
  dlopen("/System/Library/PrivateFrameworks/AppleIDSSOAuthentication.framework/AppleIDSSOAuthentication",RTLD_LAZY|RTLD_LOCAL);
  manager=NSClassFromString(@"AIDAServiceOwnersManager");
 }
 Method method=class_getClassMethod(manager,NSSelectorFromString(@"serviceOwnerBundles"));
 if(!method||method_getNumberOfArguments(method)!=2) {
  os_log_error(OS_LOG_DEFAULT,"ACCOUNT15_OWNER18 install-failed");return;
 }
 NSBundle *copy=[NSBundle bundleWithPath:owner18Embedded];NSError *error=nil;
 BOOL loaded=[copy loadAndReturnError:&error];Class principal=loaded?copy.principalClass:Nil;
 SEL supported=NSSelectorFromString(@"supportedServices");
 id services=principal&&[principal respondsToSelector:supported]?[principal performSelector:supported]:nil;
 BOOL cloud=[services respondsToSelector:@selector(containsObject:)]&&[services containsObject:@"com.apple.AppleID.Service.Cloud"];
 if(!loaded||!principal||!cloud) {
  os_log_error(OS_LOG_DEFAULT,"ACCOUNT15_OWNER18 cloud-failed loaded=%d principal=%d code=%ld",loaded,principal!=Nil,(long)(error?error.code:0));return;
 }
 owner18Bundles=(void*)method_setImplementation(method,(IMP)owner18RoutedBundles);
 // Original supportedServices builds the original bundle/principal-class map;
 // it does not instantiate an account owner or submit authentication.
 id registered=[manager performSelector:supported];
 BOOL ready=[registered respondsToSelector:@selector(containsObject:)]&&[registered containsObject:@"com.apple.AppleID.Service.Cloud"];
 fprintf(stderr,"ACCOUNT15_OWNER18 registered-cloud=%d original-plugin=1 original-authentication=1\n",ready);
 if(ready)os_log(OS_LOG_DEFAULT,"ACCOUNT15_OWNER18 cloud-ready registered-cloud=1 original-plugin=1 original-authentication=1");
 else os_log_error(OS_LOG_DEFAULT,"ACCOUNT15_OWNER18 cloud-failed registered-cloud=0");
}
