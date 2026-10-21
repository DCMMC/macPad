// Private namespace and exact guest LaunchAgent session compatibility.
// No changes to policy evaluation, authentication replies or caller audit data.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <xpc/xpc.h>
#include <unistd.h>
#include <string.h>
static const char *la18Names[]={"com.apple.CoreAuthentication.daemon","com.apple.CoreAuthentication.daemon.libxpc","com.apple.CoreAuthentication.daemon.EndpointProvider","com.apple.LocalAuthentication.RemoteUIHost","com.apple.LocalAuthentication.AuthenticationHintsProvider","com.apple.LocalAuthentication.apd","com.apple.LocalAuthentication.appassword","com.apple.LocalAuthentication.aptouchid","com.apple.LocalAuthentication.apctk","com.apple.CoreAuthentication.agent","com.apple.CoreAuthentication.agent.libxpc"};
static char la18Private[11][160];
static void*(*la18Swap)(void*,int,const char*,char**);
static void*la18UserSession(void *p,int key,const char *input,char **output){
 void *error=la18Swap(p,key,input,output);
 if(!error&&key==6&&!input&&output&&*output&&!strcmp(*output,"System")){
  char *user=strdup("Aqua");if(user){free(*output);*output=user;}
 }
 return error;
}
// Observe only the fixed system ModuleACM bundle's loader diagnostic. The
// original load and error are forwarded; no authentication data is inspected.
static BOOL(*la18BundleLoad)(id,SEL,NSError**);
static BOOL la18BundleObserver(NSBundle *bundle,SEL sel,NSError **error){
 BOOL result=la18BundleLoad(bundle,sel,error);
 if([bundle.bundlePath isEqualToString:@"/System/Library/Frameworks/LocalAuthentication.framework/Support/ModulePlugins/ModuleACM.bundle"]){
  NSError *e=error?*error:nil;
  fprintf(stderr,"ACCOUNT15_LA18 ModuleACM-load=%d code=%ld\n",result,(long)(e?e.code:0));
  if(!result&&[e.domain isEqualToString:NSCocoaErrorDomain]&&e.code==3588){
   for(NSString *key in @[NSDebugDescriptionErrorKey,NSLocalizedFailureReasonErrorKey]){
    NSString *s=e.userInfo[key];if(![s isKindOfClass:NSString.class])continue;
    // Loader failure for this fixed executable contains static image/symbol
    // names only. Emit recognized loader clauses, never the full userInfo.
    for(NSString *line in [s componentsSeparatedByString:@"\n"]){
     NSString *l=[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
     if([l hasPrefix:@"dlopen(/System/Library/Frameworks/LocalAuthentication.framework/Support/ModulePlugins/ModuleACM.bundle/"]||[l hasPrefix:@"Symbol not found:"]||[l hasPrefix:@"Library not loaded:"]||[l hasPrefix:@"Reason:"]||[l hasPrefix:@"Expected in:"])
      fprintf(stderr,"ACCOUNT15_LA18 loader=%s\n",[l substringToIndex:MIN(l.length,1000)].UTF8String);
    }
   }
  }
 }
 return result;
}
static const char *la18Map(const char *n){if(n)for(int i=0;i<11;i++)if(!strcmp(n,la18Names[i]))return la18Private[i];return n;}
static NSString *la18String(NSString *n){const char*a=n.UTF8String,*b=la18Map(a);return a&&b!=a?[NSString stringWithUTF8String:b]:n;}
static id(*la18Connect)(id,SEL,NSString*,NSUInteger);
static id la18Connection(id o,SEL s,NSString*n,NSUInteger flags){NSString*m=la18String(n);return la18Connect(o,s,m,m!=n?flags&~2UL:flags);}
static id(*la18Listen)(id,SEL,NSString*);
static id la18Listener(id o,SEL s,NSString*n){NSString*m=la18String(n);if(m!=n)fprintf(stderr,"ACCOUNT15_LA18 listener=%s\n",m.UTF8String);return la18Listen(o,s,m);}
static xpc_connection_t(*la18Mach)(const char*,dispatch_queue_t,uint64_t);
static xpc_connection_t la18CreateMach(const char*n,dispatch_queue_t q,uint64_t flags){const char*m=la18Map(n);return la18Mach(m,q,m!=n&&!(flags&1)?flags&~2ULL:flags);}
__attribute__((constructor))static void install(void){
 const char*v=getenv("MACPAD_TARGET_MACOS_VERSION"),*root=getenv("MACWS_CHROOT_HOST_ROOT"),*opt=getenv("MACPAD_ACCOUNT15_LA");
 if(!opt||strcmp(opt,"1"))return;
 char path[2048];uint32_t size=sizeof(path);
 if(!v||strcmp(v,"15.6.1")||!root||(strcmp(root,"/var/mnt/rootfs")&&strcmp(root,"/private/var/mnt/rootfs"))||_NSGetExecutablePath(path,&size))_exit(78);
 BOOL ctk=!strcmp(path,"/usr/local/libexec/macpad-account15/ctk/ctkd");
 BOOL core=!strcmp(path,"/usr/local/libexec/macpad-account15/coreauth/coreauthd");
 BOOL agent=!strcmp(path,"/usr/local/libexec/macpad-account15/coreauth-agent/coreauthd");
 if((!ctk&&!core&&!agent)||((ctk||agent)&&geteuid()!=501)||(core&&geteuid()!=0))_exit(78);
 if(core||agent){Method m=class_getInstanceMethod(NSBundle.class,@selector(loadAndReturnError:));if(!m)_exit(78);la18BundleLoad=(void*)method_setImplementation(m,(IMP)la18BundleObserver);}
 for(int i=0;i<11;i++)snprintf(la18Private[i],160,"com.macpad.account15.%s%s",(ctk||agent)&&i>=3&&i<=8?"user.":"",la18Names[i]+10);
 Method a=class_getInstanceMethod(NSXPCConnection.class,@selector(initWithMachServiceName:options:)),b=class_getInstanceMethod(NSXPCListener.class,@selector(initWithMachServiceName:));
 if(!a||!b)_exit(78);
 la18Connect=(void*)method_setImplementation(a,(IMP)la18Connection);la18Listen=(void*)method_setImplementation(b,(IMP)la18Listener);
 void*(*image)(const char*)=dlsym(RTLD_DEFAULT,"MSGetImageByName");void*(*symbol)(void*,const char*)=dlsym(RTLD_DEFAULT,"MSFindSymbol");void(*hook)(void*,void*,void**)=dlsym(RTLD_DEFAULT,"MSHookFunction");
 void*x=image?image("/usr/lib/system/libxpc.dylib"):NULL;void*t=x&&symbol?symbol(x,"_xpc_connection_create_mach_service"):NULL;
 if(!hook||!t)_exit(78);hook(t,(void*)la18CreateMach,(void**)&la18Mach);
 if(ctk||agent){
  const char *session=getenv("MACPAD_ACCOUNT15_USER_SESSION"),*home=getenv("HOME");
  if(!session||strcmp(session,"Aqua")||!home||strcmp(home,"/Users/mobile")||getuid()!=501)_exit(78);
  void *swap=symbol(x,"_vproc_swap_string");if(!swap)_exit(78);
  hook(swap,(void*)la18UserSession,(void**)&la18Swap);
  char *actual=NULL;void *error=la18UserSession(NULL,6,NULL,&actual);BOOL ok=!error&&actual&&!strcmp(actual,"Aqua");free(actual);if(!ok)_exit(78);
 }
 fprintf(stderr,"ACCOUNT15_LA18 exact-guest=%s private-services=11 original-authentication=1 user-session=%d\n",ctk?"ctkd":agent?"coreauth-agent":"coreauthd",ctk||agent);
}
