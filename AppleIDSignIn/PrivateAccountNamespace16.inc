// Opt-in account domain only. No account result, audit identity or policy reply
// is fabricated. Stable aliases preserve actual bootstrap/notify/XPC behavior.
#include <pthread.h>
#include <notify.h>
#include <xpc/xpc.h>
static const char *mapped(const char*);
static NSString *mappedString(NSString*);
static pthread_mutex_t domainLock=PTHREAD_MUTEX_INITIALIZER;
static char domainOriginal[128][160],domainPrivate[128][192];
static unsigned domainCount;
static const char *mapAccountFamily(const char*n){
 const char*families[]={"com.apple.accountsd.","com.apple.ak.","com.apple.aa.","com.apple.securityd.","com.apple.security.","com.apple.aps.","com.apple.identityservicesd.","com.apple.cdp."};
 BOOL belongs=NO;for(unsigned i=0;i<sizeof(families)/sizeof(*families);i++)if(!strncmp(n,families[i],strlen(families[i]))){belongs=YES;break;}
 if(!belongs)return n;
 if(strlen(n)>=sizeof(domainOriginal[0]))_exit(78);
 pthread_mutex_lock(&domainLock);
 for(unsigned i=0;i<domainCount;i++)if(!strcmp(n,domainOriginal[i])){pthread_mutex_unlock(&domainLock);return domainPrivate[i];}
 if(domainCount>=128){pthread_mutex_unlock(&domainLock);_exit(78);}
 unsigned i=domainCount++;strcpy(domainOriginal[i],n);
 int size=snprintf(domainPrivate[i],sizeof(domainPrivate[i]),"com.macpad.account15.%s",n+10);
 pthread_mutex_unlock(&domainLock);
 if(size<0||(size_t)size>=sizeof(domainPrivate[i]))_exit(78);
 return domainPrivate[i];
}
static kern_return_t(*domainCheckin2)(mach_port_t,const char*,mach_port_t*,uint64_t);
static kern_return_t privateCheckin2(mach_port_t p,const char*n,mach_port_t*r,uint64_t flags){return domainCheckin2(p,mapped(n),r,flags);}
static kern_return_t(*domainCheckin3)(mach_port_t,const char*,mach_port_t*,unsigned char*,uint64_t);
static kern_return_t privateCheckin3(mach_port_t p,const char*n,mach_port_t*r,unsigned char*instance,uint64_t flags){return domainCheckin3(p,mapped(n),r,instance,flags);}
static void(*domainActivityRegister)(const char*,xpc_object_t,xpc_activity_handler_t);
static void privateActivityRegister(const char*n,xpc_object_t criteria,xpc_activity_handler_t handler){domainActivityRegister(mapped(n),criteria,handler);}
static void(*domainActivityUnregister)(const char*);
static void privateActivityUnregister(const char*n){domainActivityUnregister(mapped(n));}
static uint32_t(*domainNotifyPost)(const char*);
static uint32_t privateNotifyPost(const char*n){return domainNotifyPost(mapped(n));}
static uint32_t(*domainNotifyDispatch)(const char*,int*,dispatch_queue_t,notify_handler_t);
static uint32_t privateNotifyDispatch(const char*n,int*t,dispatch_queue_t q,notify_handler_t h){return domainNotifyDispatch(mapped(n),t,q,h);}
static uint32_t(*domainNotifyCheck)(const char*,int*);
static uint32_t privateNotifyCheck(const char*n,int*t){return domainNotifyCheck(mapped(n),t);}

// Match the existing Metal_hooks.x distributed LaunchServices mapping while
// adding account names. Client binding interposition avoids the known crashes
// from inline-patching CoreFoundation's notification implementations.
static NSString *privateDistributedName(NSString*n){
 if(!n)return n;
 if(enabled&&[n isEqualToString:@"com.apple.LaunchServices.applicationRegistered"])
  return @"com.macwsguide.macOS.LaunchServices.applicationRegistered";
 return mappedString(n);
}
static CFStringRef privateCFName(CFNotificationCenterRef center,CFStringRef n){
 if(!enabled||!center||!n)return n;
 if(center==CFNotificationCenterGetDistributedCenter())return (__bridge CFStringRef)privateDistributedName((__bridge NSString*)n);
 if(center==CFNotificationCenterGetDarwinNotifyCenter())return (__bridge CFStringRef)mappedString((__bridge NSString*)n);
 return n;
}
static void accountCFPost(CFNotificationCenterRef c,CFStringRef n,const void*o,CFDictionaryRef d,CFOptionFlags f){CFNotificationCenterPostNotificationWithOptions(c,privateCFName(c,n),o,d,f);}
static void accountCFPostImmediate(CFNotificationCenterRef c,CFStringRef n,const void*o,CFDictionaryRef d,Boolean f){CFNotificationCenterPostNotification(c,privateCFName(c,n),o,d,f);}
static void accountCFObserve(CFNotificationCenterRef c,const void*o,CFNotificationCallback cb,CFStringRef n,const void*object,CFNotificationSuspensionBehavior b){CFNotificationCenterAddObserver(c,o,cb,privateCFName(c,n),object,b);}
static void accountCFRemove(CFNotificationCenterRef c,const void*o,CFStringRef n,const void*object){CFNotificationCenterRemoveObserver(c,o,privateCFName(c,n),object);}
__attribute__((used,section("__DATA,__interpose")))static const struct{const void*replacement;const void*original;}accountCFHooks[]={
 {(const void*)accountCFPost,(const void*)CFNotificationCenterPostNotificationWithOptions},
 {(const void*)accountCFPostImmediate,(const void*)CFNotificationCenterPostNotification},
 {(const void*)accountCFObserve,(const void*)CFNotificationCenterAddObserver},
 {(const void*)accountCFRemove,(const void*)CFNotificationCenterRemoveObserver}};

static void(*distributedPostOptions)(id,SEL,NSString*,id,NSDictionary*,NSUInteger);
static void accountDistributedPostOptions(id o,SEL s,NSString*n,id object,NSDictionary*d,NSUInteger options){distributedPostOptions(o,s,privateDistributedName(n),object,d,options);}
static void(*distributedPostImmediate)(id,SEL,NSString*,id,NSDictionary*,BOOL);
static void accountDistributedPostImmediate(id o,SEL s,NSString*n,id object,NSDictionary*d,BOOL immediately){distributedPostImmediate(o,s,privateDistributedName(n),object,d,immediately);}
static void(*distributedObserve)(id,SEL,id,SEL,NSString*,id);
static void accountDistributedObserve(id o,SEL s,id observer,SEL callback,NSString*n,id object){distributedObserve(o,s,observer,callback,privateDistributedName(n),object);}
static void(*distributedObserveBehavior)(id,SEL,id,SEL,NSString*,id,NSUInteger);
static void accountDistributedObserveBehavior(id o,SEL s,id observer,SEL callback,NSString*n,id object,NSUInteger behavior){distributedObserveBehavior(o,s,observer,callback,privateDistributedName(n),object,behavior);}
static void(*distributedRemove)(id,SEL,id,NSString*,id);
static void accountDistributedRemove(id o,SEL s,id observer,NSString*n,id object){distributedRemove(o,s,observer,privateDistributedName(n),object);}
static BOOL installDistributedMethod(Class c,SEL selector,IMP replacement,IMP*original){
 Method m=class_getInstanceMethod(c,selector);if(!m)return NO;
 *original=method_getImplementation(m);
 // If inherited, add an override on this concrete distributed class. Never
 // replace the base local NSNotificationCenter method.
 if(!class_addMethod(c,selector,replacement,method_getTypeEncoding(m)))
  method_setImplementation(class_getInstanceMethod(c,selector),replacement);
 return YES;
}
static void installDistributedNamespace(void){
 Class c=object_getClass([NSDistributedNotificationCenter defaultCenter]);
 if(!c||!installDistributedMethod(c,@selector(postNotificationName:object:userInfo:options:),(IMP)accountDistributedPostOptions,(IMP*)&distributedPostOptions)
  ||!installDistributedMethod(c,@selector(postNotificationName:object:userInfo:deliverImmediately:),(IMP)accountDistributedPostImmediate,(IMP*)&distributedPostImmediate)
  ||!installDistributedMethod(c,@selector(addObserver:selector:name:object:),(IMP)accountDistributedObserve,(IMP*)&distributedObserve)
  ||!installDistributedMethod(c,@selector(addObserver:selector:name:object:suspensionBehavior:),(IMP)accountDistributedObserveBehavior,(IMP*)&distributedObserveBehavior)
  ||!installDistributedMethod(c,@selector(removeObserver:name:object:),(IMP)accountDistributedRemove,(IMP*)&distributedRemove))_exit(78);
}
