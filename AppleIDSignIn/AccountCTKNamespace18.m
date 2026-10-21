// Exact guest ctkd only; macOS user bag selector maps to native device bag.
// Preserve original key generation, audit tokens,
// entitlement checks, SEP options and all success/error replies.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <sys/sysctl.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string.h>
static id (*ctk18External)(id,SEL);
static int(*ctk18Bag)(id,SEL,BOOL);
static int ctk18BagObserver(id self,SEL sel,BOOL system){
 int bag=ctk18Bag(self,sel,system);
 // Native 16.2 TKLocalSEPKey.keybagHandle returns the real device bag (0).
 // Only the macOS user-session selector is translated in this exact guest;
 // system (-6), testing/explicit handles and every real AKS reply stay intact.
 int target=!system&&bag==-3?0:bag;
 fprintf(stderr,"ACCOUNT15_CTK18 original-bag=%d native-bag=%d force-system=%d\n",bag,target,system);return target;
}
static BOOL(*ctk18AKSError)(id,SEL,NSError**,int,id,id,id,id);
static BOOL ctk18AKSErrorObserver(id self,SEL sel,NSError **error,int status,id context,id operation,id params,id message){
 fprintf(stderr,"ACCOUNT15_CTK18 AKS-error status=%d hex=%08x\n",status,(unsigned)status);
 return ctk18AKSError(self,sel,error,status,context,operation,params,message);
}
static void ctk18Error(NSError *error){
 for(int i=0;error&&i<6;i++){
  const char *domain="other";
  for(NSString *n in @[@"NSCocoaErrorDomain",@"NSOSStatusErrorDomain",@"com.apple.LocalAuthentication",@"com.apple.LocalAuthentication.ErrorDomain",@"LAErrorDomain",@"com.apple.CoreAuthentication",@"CryptoTokenKit"])
   if([error.domain isEqualToString:n]){domain=n.UTF8String;break;}
  fprintf(stderr,"ACCOUNT15_CTK18 context-error depth=%d domain=%s code=%ld\n",i,domain,(long)error.code);
  id next=error.userInfo[NSUnderlyingErrorKey];error=[next isKindOfClass:NSError.class]?next:nil;
 }
}
static void(*ctk18ConnectionResult)(id,SEL,id,id,id,NSError*);
static void ctk18ConnectionObserver(id self,SEL sel,id proxy,id uuid,id proxyId,NSError *error){
 fprintf(stderr,"ACCOUNT15_CTK18 LA-connection proxy=%d error=%ld\n",proxy!=nil,(long)(error?error.code:0));ctk18Error(error);
 ctk18ConnectionResult(self,sel,proxy,uuid,proxyId,error);
}
static id(*ctk18SyncExternal)(id,SEL,NSError**);
static id ctk18SyncObserver(id self,SEL sel,NSError **error){
 id result=ctk18SyncExternal(self,sel,error);
 fprintf(stderr,"ACCOUNT15_CTK18 LA-sync-externalized present=%d\n",result!=nil);if(error)ctk18Error(*error);
 return result;
}
static id ctk18ExternalObserver(id self,SEL sel){
 id result=ctk18External(self,sel);
 fprintf(stderr,"ACCOUNT15_CTK18 LAContext-externalized present=%d\n",result!=nil);
 return result;
}
static id (*ctk18AuthContext)(id,SEL,NSError**);
static id ctk18AuthObserver(id self,SEL sel,NSError **error){
 id result=ctk18AuthContext(self,sel,error);
 fprintf(stderr,"ACCOUNT15_CTK18 auth-context present=%d error=%ld\n",result!=nil,(long)(error&&*error?(*error).code:0));
 return result;
}
static NSString *ctk18Name(NSString *name){
 if([name isEqualToString:@"com.apple.ctkd.token-client"])return @"com.macpad.account15.ctkd.token-client";
 if([name isEqualToString:@"com.apple.ctkd.slot-client"])return @"com.macpad.account15.ctkd.slot-client";
 if([name isEqualToString:@"com.apple.ctkd.slot-registry"])return @"com.macpad.account15.ctkd.slot-registry";
 return name;
}
static id (*ctk18Client)(id,SEL,NSString*,NSUInteger);
static id (*ctk18Listener)(id,SEL,NSString*);
static id ctk18ClientInit(id obj,SEL sel,NSString *name,NSUInteger options){
 NSString *n=ctk18Name(name);if(n!=name)options&=~2UL;
 if([name hasPrefix:@"com.apple.CoreAuthentication."]||[name hasPrefix:@"com.apple.LocalAuthentication."])
  fprintf(stderr,"ACCOUNT15_CTK18 authentication-service=%s options=%lu\n",name.UTF8String,(unsigned long)options);
 return ctk18Client(obj,sel,n,options);
}
static id ctk18ListenerInit(id obj,SEL sel,NSString *name){
 NSString *n=ctk18Name(name);
 if(n!=name)fprintf(stderr,"ACCOUNT15_CTK18 original-listener=1 private-service=%s\n",n.UTF8String);
 return ctk18Listener(obj,sel,n);
}
__attribute__((constructor))static void install(void){
 const char *v=getenv("MACPAD_TARGET_MACOS_VERSION"),*root=getenv("MACWS_CHROOT_HOST_ROOT"),*opt=getenv("MACPAD_ACCOUNT15_CTK");
 if(!opt||strcmp(opt,"1"))return;
 char path[2048];uint32_t size=sizeof(path);
 if(!v||strcmp(v,"15.6.1")||!root||(strcmp(root,"/var/mnt/rootfs")&&strcmp(root,"/private/var/mnt/rootfs"))||geteuid()!=501||_NSGetExecutablePath(path,&size)||
   (strcmp(path,"/usr/local/libexec/macpad-account15/ctk/ctkd")&&strcmp(path,"/var/mnt/rootfs/usr/local/libexec/macpad-account15/ctk/ctkd")&&strcmp(path,"/private/var/mnt/rootfs/usr/local/libexec/macpad-account15/ctk/ctkd")))_exit(78);
 char kernel[64]={0};size_t kernelLength=sizeof(kernel);
 if(sysctlbyname("kern.osrelease",kernel,&kernelLength,NULL,0)||strcmp(kernel,"22.2.0"))_exit(78);
 int(*lockState)(int,unsigned*)=dlsym(RTLD_DEFAULT,"aks_get_lock_state");
 if(!lockState)_exit(78);
 for(int i=0;i<2;i++){int bag=i?0:-3;unsigned state=0;int status=lockState(bag,&state);fprintf(stderr,"ACCOUNT15_CTK18 bag-state selector=%d status=%d state=%u\n",bag,status,status?0:state);}
 Method c=class_getInstanceMethod(NSXPCConnection.class,@selector(initWithMachServiceName:options:));
 Method l=class_getInstanceMethod(NSXPCListener.class,@selector(initWithMachServiceName:));
 if(!c||!l)_exit(78);
 ctk18Client=(void*)method_setImplementation(c,(IMP)ctk18ClientInit);
 ctk18Listener=(void*)method_setImplementation(l,(IMP)ctk18ListenerInit);
 Class la=objc_getClass("LAContext"),tk=objc_getClass("TKLocalSEPKey");
 Method ext=la?class_getInstanceMethod(la,sel_registerName("externalizedContext")):NULL;
 Method auth=tk?class_getInstanceMethod(tk,sel_registerName("authContextWithError:")):NULL;
 if(ext)ctk18External=(void*)method_setImplementation(ext,(IMP)ctk18ExternalObserver);
 if(auth)ctk18AuthContext=(void*)method_setImplementation(auth,(IMP)ctk18AuthObserver);
 Method bag=tk?class_getClassMethod(tk,sel_registerName("keybagHandleForceSystemSession:")):NULL;
 Method aks=tk?class_getInstanceMethod(tk,sel_registerName("error:withAKSReturn:ACMHandle:AKSOperation:params:message:")):NULL;
 if(bag)ctk18Bag=(void*)method_setImplementation(bag,(IMP)ctk18BagObserver);
 if(aks)ctk18AKSError=(void*)method_setImplementation(aks,(IMP)ctk18AKSErrorObserver);
 Class client=objc_getClass("LAClient");
 Method connection=client?class_getInstanceMethod(client,sel_registerName("_handleConnectionResult:uuid:proxyId:error:")):NULL;
 Method sync=client?class_getInstanceMethod(client,sel_registerName("synchronousExternalizedContextWithError:")):NULL;
 if(connection)ctk18ConnectionResult=(void*)method_setImplementation(connection,(IMP)ctk18ConnectionObserver);
 if(sync)ctk18SyncExternal=(void*)method_setImplementation(sync,(IMP)ctk18SyncObserver);
 fprintf(stderr,"ACCOUNT15_CTK18 metadata-observers external=%d auth=%d\n",ext!=NULL,auth!=NULL);
 if(ext)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_global_queue(0,0),^{
  id context=[(id)la new];
  id result=ctk18External(context,sel_registerName("externalizedContext"));
  fprintf(stderr,"ACCOUNT15_CTK18 own-LA-preflight context=%d externalized=%d\n",context!=nil,result!=nil);
  [context release];
 });
 fprintf(stderr,"ACCOUNT15_CTK18 exact-guest=1 three-private-names=1 original-protocols=1\n");
}
