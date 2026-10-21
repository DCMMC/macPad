// Guest-only namespace for Apple's real macOS account/keychain services.
// No credentials, account objects, replies, audit identities or TLS checks are
// synthesized. Native iPadOS endpoints and databases are not registration targets.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <sys/stat.h>
static BOOL enabled;
static const char *names[]={
 "com.apple.accountsd.accountmanager","com.apple.accountsd.oauthsigner","com.apple.accountsd.oopa",
 "com.apple.SecurityServer","com.apple.securityd.xpc","com.apple.securityd","com.apple.securityd.systemkeychain",
 "com.apple.ak.auth.xpc","com.apple.ak.anisette.xpc","com.apple.ak.custodian.xpc","com.apple.ak.inheritance.xpc",
 "com.apple.ak.walrus.xpc","com.apple.ak.signinwithapple.xpc","com.apple.ak.authorizationservices.xpc",
 "com.apple.ak.privateemail.xpc","com.apple.ak.puffin.xpc","com.apple.ak.appleidpasskey.xpc","com.apple.ak.aps",
 "com.apple.aa.daemon.xpc","com.apple.aa.custodian.xpc","com.apple.aa.inheritance.xpc","com.apple.aa.usernotifications.xpc",
 // All eight actual com.apple.secd LaunchAgent registrations must stay
 // private before considering a guest modern-keychain daemon. This does
 // not qualify secd's keybag effects or start that daemon.
 "com.apple.securityd.aps","com.apple.securityd.ckks","com.apple.securityd.general","com.apple.securityd.sos",
 "com.apple.security.escrow-update","com.apple.security.kcsharing",
 "com.apple.security.octagon","com.apple.cdp.daemon","com.apple.xpc.amsaccountsd",
 "com.apple.familycircle.agent","com.apple.cloudd","com.apple.contactsd","com.apple.corefollowup.agent",
 "com.apple.identityservicesd.embedded.auth","com.apple.identityservicesd.idquery.desktop.auth",
 "com.apple.identityservicesd.idquery.embedded.auth","com.apple.AppSSO.service-xpc",
 "com.apple.apsd","com.apple.aps.aa","com.apple.aps.appleaccountd",
 "com.apple.private.alloy.accounts.representative-idswake",
 "com.apple.usernotifications.delegate.com.apple.appleaccount.notifications"
};
static char private_names[sizeof(names)/sizeof(*names)][160];
#include "PrivateAccountNamespace16.inc"
static const char *mapped(const char *n){
 if(!enabled||!n)return n;
 if(!strcmp(n,"com.apple.trustd"))return "com.macpad.main15.trustd.20261005";
 if(!strcmp(n,"com.apple.trustd.agent"))return "com.macpad.main15.trustd.agent.20261005";
 if(!strcmp(n,"com.apple.containermanagerd"))return geteuid()==501?"com.macpad.native15.container.user501.20261018":"com.macpad.stage15.container.20261005";
 if(!strcmp(n,"com.apple.containermanagerd.system"))return "com.macpad.stage15.container.system.20261005";
 for(unsigned i=0;i<sizeof(names)/sizeof(*names);i++)if(!strcmp(n,names[i]))return private_names[i];
 return mapAccountFamily(n);
}
static NSString *mappedString(NSString *n){
 const char *a=n.UTF8String,*b=mapped(a);return a&&b!=a?[NSString stringWithUTF8String:b]:n;
}
static id(*init_client)(id,SEL,NSString*,NSUInteger);
static id client(id o,SEL s,NSString*n,NSUInteger flags){
 NSString*m=mappedString(n);if(m!=n)flags&=~2UL; // user launchd namespace, real lookup
 return init_client(o,s,m,flags);
}
static id(*init_listener)(id,SEL,NSString*);
static id listener(id o,SEL s,NSString*n){return init_listener(o,s,mappedString(n));}
static kern_return_t(*lookup)(mach_port_t,const char*,mach_port_t*);
static kern_return_t look(mach_port_t p,const char*n,mach_port_t*r){return lookup(p,mapped(n),r);}
static kern_return_t(*checkin)(mach_port_t,const char*,mach_port_t*);
static kern_return_t check(mach_port_t p,const char*n,mach_port_t*r){return checkin(p,mapped(n),r);}
static kern_return_t(*lookup2)(mach_port_t,const char*,mach_port_t*,pid_t,uint64_t);
static kern_return_t look2(mach_port_t p,const char*n,mach_port_t*r,pid_t t,uint64_t f){return lookup2(p,mapped(n),r,t,f);}
static void*(*create_mach)(const char*,void*,uint64_t);
static void *create(const char*n,void*q,uint64_t f){
 const char*m=mapped(n);if(m!=n && !(f&1))f&=~2ULL;
 return create_mach(m,q,f);
}
#include "AccountICloudHelper22.inc"
__attribute__((constructor)) static void install(void){
 verifyICloudHelper22();
 const char*v=getenv("MACPAD_TARGET_MACOS_VERSION"),*root=getenv("MACWS_CHROOT_HOST_ROOT"),*opt=getenv("MACPAD_PRIVATE_APPLE_ACCOUNT");
 if(!v||strcmp(v,"15.6.1")||!root||(strcmp(root,"/var/mnt/rootfs")&&strcmp(root,"/private/var/mnt/rootfs"))||!opt||strcmp(opt,"1"))return;
 // Identity diagnostics can log account attributes. Refuse the entire
 // opt-in backend instead of permitting credential-bearing calls under
 // that diagnostic environment. No logs or global settings are hidden.
 if(getenv("MACWS_IDENTITY_DIAGNOSTICS")){
  fprintf(stderr,"ACCOUNT15 refusing account flow with identity diagnostics enabled\n");_exit(78);
 }
 for(unsigned i=0;i<sizeof(names)/sizeof(*names);i++)snprintf(private_names[i],160,"com.macpad.account15.%s",names[i]+10);
 void *(*image)(const char*)=dlsym(RTLD_DEFAULT,"MSGetImageByName");
 void *(*symbol)(void*,const char*)=dlsym(RTLD_DEFAULT,"MSFindSymbol");
 void (*hook)(void*,void*,void**)=dlsym(RTLD_DEFAULT,"MSHookFunction");
 void*x=image?image("/usr/lib/system/libxpc.dylib"):NULL;
 const char*entries[]={"_bootstrap_look_up","_bootstrap_check_in","_bootstrap_look_up2","_xpc_connection_create_mach_service","_bootstrap_check_in2","_bootstrap_check_in3","_xpc_activity_register","_xpc_activity_unregister"};
 void*replacements[]={(void*)look,(void*)check,(void*)look2,(void*)create,(void*)privateCheckin2,(void*)privateCheckin3,(void*)privateActivityRegister,(void*)privateActivityUnregister};
 void**originals[]={(void**)&lookup,(void**)&checkin,(void**)&lookup2,(void**)&create_mach,(void**)&domainCheckin2,(void**)&domainCheckin3,(void**)&domainActivityRegister,(void**)&domainActivityUnregister};
 void*targets[8]={0};
 for(int i=0;i<8;i++)targets[i]=x&&symbol?symbol(x,entries[i]):NULL;
 void*notifyImage=image?image("/usr/lib/system/libsystem_notify.dylib"):NULL;
 const char*notifyEntries[]={"_notify_post","_notify_register_dispatch","_notify_register_check"};
 void*notifyReplacements[]={(void*)privateNotifyPost,(void*)privateNotifyDispatch,(void*)privateNotifyCheck};
 void**notifyOriginals[]={(void**)&domainNotifyPost,(void**)&domainNotifyDispatch,(void**)&domainNotifyCheck};
 void*notifyTargets[3]={0};
 if(!hook)_exit(78);
 for(int i=0;i<8;i++)if(!targets[i]){fprintf(stderr,"ACCOUNT15 extended namespace unavailable index=%d\n",i);_exit(78);}
 for(int i=0;i<3;i++){notifyTargets[i]=notifyImage&&symbol?symbol(notifyImage,notifyEntries[i]):NULL;if(!notifyTargets[i]){fprintf(stderr,"ACCOUNT15 notification namespace unavailable index=%d\n",i);_exit(78);}}
 enabled=YES;
 for(int i=0;i<8;i++)hook(targets[i],replacements[i],originals[i]);
 for(int i=0;i<3;i++)hook(notifyTargets[i],notifyReplacements[i],notifyOriginals[i]);
 Method a=class_getInstanceMethod(NSXPCConnection.class,@selector(initWithMachServiceName:options:));
 Method b=class_getInstanceMethod(NSXPCListener.class,@selector(initWithMachServiceName:));
 if(!a||!b)_exit(78);
 init_client=(void*)method_setImplementation(a,(IMP)client);
 init_listener=(void*)method_setImplementation(b,(IMP)listener);
 installDistributedNamespace();
 installICloudHelper22();
}
