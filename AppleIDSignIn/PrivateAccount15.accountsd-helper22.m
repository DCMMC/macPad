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
#include "PrivateAccountsdRole24.inc"
static const char *mapped(const char *n){
 if(!enabled||!n)return n;
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
#include "AccountICloudClient22.inc"
__attribute__((constructor)) static void install(void){
 const char*v=getenv("MACPAD_TARGET_MACOS_VERSION"),*root=getenv("MACWS_CHROOT_HOST_ROOT"),*opt=getenv("MACPAD_PRIVATE_APPLE_ACCOUNT");
 if(!v||strcmp(v,"15.6.1")||!root||(strcmp(root,"/var/mnt/rootfs")&&strcmp(root,"/private/var/mnt/rootfs"))||!opt||strcmp(opt,"1")){if(privateAccountsdIsFixture())_exit(78);return;}
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
 if(privateAccountsdIsFixture()){verifyPrivateAccountsdRole();installICloudClient22();return;}
 const char *requireSandbox=getenv("MACPAD_ACCOUNT15_REQUIRE_SANDBOX");
 if(requireSandbox && !strcmp(requireSandbox,"1")) {
  const char *program=getprogname();
  if(!program||strcmp(program,"appleaccountd"))_exit(78);
  int (*check)(pid_t,const char*,int,...)=dlsym(RTLD_DEFAULT,"sandbox_check");
  int (*apply)(const char*,int,void*)=dlsym(RTLD_DEFAULT,"__sandbox_ms");
  if(!check||!apply||check(getpid(),NULL,0)!=0)_exit(78);
  // Actual 24G90 and native16.2 disassembly both select the kernel's named
  // profile entry at flag2. Both were crosschecked; a native16.2 probe
  // demonstrated real confinement and exact-file executable extension use.
  // Apply the original temporary-sandbox before daemon main, after loader
  // compatibility initialization. No sandbox-query or IDS-return override.
  char *(*issue)(const char*,const char*,unsigned int)=dlsym(RTLD_DEFAULT,"sandbox_extension_issue_file");
  long long (*consume)(const char*)=dlsym(RTLD_DEFAULT,"sandbox_extension_consume");
  const char *session[]={"/var/folders/zz/macws_uid501/0/","/var/folders/zz/macws_uid501/T/","/var/folders/zz/macws_uid501/C/","/Users/mobile/Library/Caches/com.apple.appleaccountd/","/Users/mobile/Library/HTTPStorages/com.apple.appleaccountd/"};
  char *tokens[5]={0};
  if(!issue||!consume||geteuid()!=501)_exit(78);
  for(int i=0;i<5;i++){
   struct stat st={0};
   if(stat(session[i],&st)||!S_ISDIR(st.st_mode)||st.st_uid!=501||(st.st_mode&0777)!=0700||access(session[i],R_OK|W_OK|X_OK))_exit(78);
   tokens[i]=issue("com.apple.app-sandbox.read-write",session[i],0);
   size_t n=tokens[i]?strnlen(tokens[i],2048):0;
   fprintf(stderr,"ACCOUNT15 session-token issued=%d resource=%d\n",n>100&&n<2048,i);
   if(n<100||n>=2048)_exit(78);
  }
  // Load the genuine immutable bundle metadata while the loader's access
  // is still available, then retain Foundation's normal cache across the
  // real sandbox transition. No Info keys or account values are invented.
  NSBundle *originalBundle=NSBundle.mainBundle;
  NSDictionary *originalInfo=originalBundle.infoDictionary;
  NSArray *requiredKeys=@[@"AACustodianContainer",@"AACustodianManateeContainer",@"AABeneficiaryContainer",@"AABeneficiaryManateeContainer"];
  if(![originalInfo[@"CFBundleIdentifier"] isEqualToString:@"com.apple.appleaccountd"])_exit(78);
  for(NSString *key in requiredKeys)if(![originalInfo[key] isKindOfClass:NSString.class]||![originalInfo[key] length])_exit(78);
  fprintf(stderr,"ACCOUNT15 original immutable metadata before-sandbox count=%lu\n",(unsigned long)originalInfo.count);
  const char *mainPath="/usr/local/libexec/macpad-account15/AppleAccountService.app/Contents/MacOS/appleaccountd";
  struct stat mainState={0};
  if(stat(mainPath,&mainState)||!S_ISREG(mainState.st_mode)||mainState.st_uid||(mainState.st_mode&022))_exit(78);
  char *mainToken=issue("com.apple.app-sandbox.read",mainPath,0);
  size_t mainTokenLength=mainToken?strnlen(mainToken,2048):0;
  if(mainTokenLength<100||mainTokenLength>=2048)_exit(78);
  const char *infoPath="/usr/local/libexec/macpad-account15/AppleAccountService.app/Contents/Info.plist";
  struct stat infoState={0};
  if(stat(infoPath,&infoState)||!S_ISREG(infoState.st_mode)||infoState.st_uid||(infoState.st_mode&022))_exit(78);
  char *infoToken=issue("com.apple.app-sandbox.read",infoPath,0);
  size_t infoLength=infoToken?strnlen(infoToken,2048):0;
  if(infoLength<100||infoLength>=2048)_exit(78);
  char *(*issueMach)(const char*,const char*,unsigned int)=dlsym(RTLD_DEFAULT,"sandbox_extension_issue_mach");
  const char *machNames[]={"com.macpad.account15.ak.anisette.xpc","com.apple.dnssd.service","com.macwsguide.host.control"};
  char *machTokens[3]={0};
  if(!issueMach)_exit(78);
  for(int i=0;i<3;i++){
   machTokens[i]=issueMach("com.apple.security.exception.mach-lookup.global-name",machNames[i],0);
   size_t n=machTokens[i]?strnlen(machTokens[i],2048):0;
   if(n<100||n>=2048)_exit(78);
  }
  const char *readPaths[]={"/System/Library","/usr/share","/private/etc/passwd","/private/etc/group"};
  char *readTokens[4]={0};
  for(int i=0;i<4;i++){
   struct stat st={0};
   if(stat(readPaths[i],&st)||(i<2?!S_ISDIR(st.st_mode):!S_ISREG(st.st_mode)))_exit(78);
   readTokens[i]=issue("com.apple.app-sandbox.read",readPaths[i],0);
   size_t n=readTokens[i]?strnlen(readTokens[i],2048):0;if(n<100||n>=2048)_exit(78);
  }
  struct {const char *profile;unsigned long long reserved[2];} request={"temporary-sandbox",{0,0}};
  // libmachook interposes both high-level sandbox_init entry points as a
  // historical no-op. Use their RE-confirmed flag2 kernel request verbatim.
  // The __sandbox_ms adapter delegates policy=Sandbox unchanged.
  int status=apply("Sandbox",1,&request),saved=errno,active=check(getpid(),NULL,0);
  fprintf(stderr,"ACCOUNT15 real named sandbox applied=%d active=%d errno=%d\n",status,active,saved);
  if(status||active==0)_exit(78);
  for(int i=0;i<5;i++){
   long long handle=consume(tokens[i]);size_t n=strlen(tokens[i]);
   volatile char *wipe=tokens[i];for(size_t j=0;j<n;j++)wipe[j]=0;free(tokens[i]);
   int accessStatus=access(session[i],R_OK|W_OK|X_OK);
   fprintf(stderr,"ACCOUNT15 session-token consumed=%d access=%d resource=%d\n",handle>0,accessStatus,i);
   if(handle<=0||accessStatus)_exit(78);
  }
  for(int i=0;i<3;i++){
   long long handle=consume(machTokens[i]);size_t n=strlen(machTokens[i]);
   volatile char *wipe=machTokens[i];for(size_t j=0;j<n;j++)wipe[j]=0;free(machTokens[i]);
   int allowed=check(getpid(),"mach-lookup",0x40000002,machNames[i]);
   fprintf(stderr,"ACCOUNT15 mach-token resource=%d consumed=%d policy=%d\n",i,handle>0,allowed);
   if(handle<=0||allowed)_exit(78);
  }
  for(int i=0;i<4;i++){
   long long handle=consume(readTokens[i]);size_t n=strlen(readTokens[i]);
   volatile char *wipe=readTokens[i];for(size_t j=0;j<n;j++)wipe[j]=0;free(readTokens[i]);
   fprintf(stderr,"ACCOUNT15 guest-read resource=%d consumed=%d access=%d\n",i,handle>0,access(readPaths[i],R_OK));
   if(handle<=0||access(readPaths[i],R_OK))_exit(78);
  }
  long long mainHandle=consume(mainToken);
  volatile char *mainWipe=mainToken;for(size_t j=0;j<mainTokenLength;j++)mainWipe[j]=0;free(mainToken);
  if(mainHandle<=0)_exit(78);
  long long infoHandle=consume(infoToken);
  volatile char *infoWipe=infoToken;for(size_t j=0;j<infoLength;j++)infoWipe[j]=0;free(infoToken);
  if(infoHandle<=0)_exit(78);
  NSDictionary *mainInfo=NSBundle.mainBundle.infoDictionary;
  const char *keyNames[]={"AACustodianContainer","AACustodianManateeContainer","AABeneficiaryContainer","AABeneficiaryManateeContainer"};
  fprintf(stderr,"ACCOUNT15 main-info count=%lu main-read-token=%d\n",(unsigned long)mainInfo.count,mainHandle>0);
  for(int i=0;i<4;i++){
   id item=mainInfo[[NSString stringWithUTF8String:keyNames[i]]];
   fprintf(stderr,"ACCOUNT15 main-info resource=%d string-length=%lu\n",i,[item isKindOfClass:NSString.class]?(unsigned long)[item length]:0);
  }
  const int keys[]={65536,65537,65538};
  const char *dirs[]={getenv("MACWS_SESSION_USER_DIR"),getenv("MACWS_SESSION_TEMP_DIR"),getenv("MACWS_SESSION_CACHE_DIR")};
  for(int i=0;i<3;i++){
   char path[1024]={0};struct stat st={0};errno=0;size_t n=confstr(keys[i],path,sizeof(path));int ce=errno;
   errno=0;int sr=dirs[i]?stat(dirs[i],&st):-1,se=errno;errno=0;int ar=dirs[i]?access(dirs[i],R_OK|W_OK|X_OK):-1,ae=errno;
   fprintf(stderr,"ACCOUNT15 session-dir key=%d confstr=%zu errno=%d stat=%d errno=%d uid=%u mode=%o access=%d errno=%d\n",keys[i],n,ce,sr,se,st.st_uid,st.st_mode&0777,ar,ae);
  }
 }
 fprintf(stderr,"ACCOUNT15 v16 private namespace installed pid=%d uid=%d services=%lu\n",getpid(),getuid(),sizeof(names)/sizeof(*names));
}
