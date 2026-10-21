// Guest-only, real APIs. A strong random legacy keychain password is protected
// by the private DP keychain, never a plaintext file or argv/environment value.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <servers/bootstrap.h>
#include <xpc/xpc.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
static const char*kcPath="/Users/mobile/Library/Keychains/macpad-account15-login.keychain-db";
static void wipe(void*b,size_t n){volatile unsigned char*p=b;while(n--)*p++=0;}
static BOOL exactPath(SecKeychainRef k){char path[2048]={0};UInt32 n=sizeof(path);return k&&SecKeychainGetPath(k,&n,path)==0&&!strcmp(path,kcPath);}
static BOOL privateRoutes(void){
 xpc_connection_t c=xpc_connection_create_mach_service("com.apple.securityd.xpc",NULL,0);
 BOOL ok=c&&!strcmp(xpc_connection_get_name(c),"com.macpad.account15.securityd.xpc");
 if(c){xpc_connection_set_event_handler(c,^(xpc_object_t e){(void)e;});xpc_connection_cancel(c);xpc_connection_resume(c);xpc_release(c);}
 mach_port_t a=MACH_PORT_NULL,b=MACH_PORT_NULL;
 kern_return_t x=bootstrap_look_up(bootstrap_port,"com.apple.SecurityServer",&a);
 kern_return_t y=bootstrap_look_up(bootstrap_port,"com.macpad.account15.SecurityServer",&b);
 ok=ok&&x==0&&y==0&&MACH_PORT_VALID(a)&&a==b;
 if(MACH_PORT_VALID(a))mach_port_deallocate(mach_task_self(),a);if(MACH_PORT_VALID(b))mach_port_deallocate(mach_task_self(),b);
 return ok;
}
int main(int argc,char**argv){@autoreleasepool{
 BOOL ensure=argc==2&&!strcmp(argv[1],"ensure"),check=argc==2&&!strcmp(argv[1],"check");
 const char*root=getenv("MACWS_CHROOT_HOST_ROOT"),*version=getenv("MACPAD_TARGET_MACOS_VERSION"),*opt=getenv("MACPAD_PRIVATE_APPLE_ACCOUNT"),*home=getenv("HOME");
 if((!ensure&&!check)||getuid()!=501||geteuid()!=501||!root||(strcmp(root,"/var/mnt/rootfs")&&strcmp(root,"/private/var/mnt/rootfs"))||!version||strcmp(version,"15.6.1")||!opt||strcmp(opt,"1")||!home||strcmp(home,"/Users/mobile")||![NSHomeDirectory() isEqualToString:@"/Users/mobile"]||!privateRoutes())return 78;
 struct stat hs;if(lstat(home,&hs)||!S_ISDIR(hs.st_mode)||hs.st_uid!=501)return 78;
 SecCodeRef code=NULL;OSStatus sc=SecCodeCopySelf(0,&code),cv=code?SecCodeCheckValidity(code,0,NULL):errSecParam;if(code)CFRelease(code);if(sc||cv)return 78;
 if(SecKeychainSetUserInteractionAllowed(false)||SecKeychainSetPreferenceDomain(kSecPreferencesDomainUser))return 78;
 SecKeychainRef old=NULL;OSStatus before=SecKeychainCopyDefault(&old);BOOL ours=exactPath(old);if(old)CFRelease(old);
 if((before==0&&!ours)||(before!=0&&before!=errSecNoDefaultKeychain)){
  fprintf(stderr,"ACCOUNT15_LOGIN_KEYCHAIN refusing-foreign-or-unreadable-default=1 status=%d\n",(int)before);return 78;
 }
 struct stat st;int found=lstat(kcPath,&st);BOOL exists=found==0;
 if((!exists&&errno!=ENOENT)||(exists&&(!S_ISREG(st.st_mode)||st.st_uid!=501||(st.st_mode&077)))||(!ensure&&!exists))return 78;
 NSDictionary*base=@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
  (__bridge id)kSecAttrService:@"com.macpad.account15.legacy-login-master-password.v1",
  (__bridge id)kSecAttrAccount:@"guest-login-keychain",
  (__bridge id)kSecAttrAccessGroup:@"com.macpad.account15.keychainunlock",
  (__bridge id)kSecUseDataProtectionKeychain:@YES,
  (__bridge id)kSecAttrSynchronizable:@NO,
  (__bridge id)kSecUseAuthenticationUI:(__bridge id)kSecUseAuthenticationUIFail};
 NSMutableDictionary*q=[base mutableCopy];q[(__bridge id)kSecReturnData]=@YES;q[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
 CFTypeRef raw=NULL;OSStatus dp=SecItemCopyMatching((__bridge CFDictionaryRef)q,&raw);
 NSMutableData*password=[NSMutableData dataWithLength:32];BOOL createdSecret=NO;
 if(dp==0&&raw&&CFGetTypeID(raw)==CFDataGetTypeID()&&CFDataGetLength(raw)==32)memcpy(password.mutableBytes,CFDataGetBytePtr(raw),32);
 else if(dp==errSecItemNotFound&&ensure&&!exists){
  if(SecRandomCopyBytes(kSecRandomDefault,password.length,password.mutableBytes)==0){
   NSMutableDictionary*item=[base mutableCopy];item[(__bridge id)kSecValueData]=password;item[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
   dp=SecItemAdd((__bridge CFDictionaryRef)item,NULL);createdSecret=dp==0;
  }else dp=errSecNotAvailable;
 }else if(dp==0)dp=errSecDecode;
 if(raw)CFRelease(raw);
 if(dp){wipe(password.mutableBytes,password.length);fprintf(stderr,"ACCOUNT15_LOGIN_KEYCHAIN protected-secret-unavailable=%d no-fallback=1\n",(int)dp);return 1;}
 SecKeychainRef kc=NULL;OSStatus open=errSecNotAvailable;BOOL createdFile=NO;
 if(!exists&&ensure){mode_t mask=umask(077);open=SecKeychainCreate(kcPath,password.length,password.bytes,false,NULL,&kc);umask(mask);createdFile=open==0;
  if(open==0&&(lstat(kcPath,&st)||!S_ISREG(st.st_mode)||st.st_uid!=501||chmod(kcPath,0600)))open=errSecIO;
 }else open=SecKeychainOpen(kcPath,&kc);
 OSStatus unlock=errSecNotAvailable,getStatus=errSecNotAvailable,setDefault=errSecNotAvailable;SecKeychainStatus flags=0;
 if(open==0&&kc&&exactPath(kc)){
  unlock=SecKeychainUnlock(kc,password.length,password.bytes,true);
  if(unlock==0)getStatus=SecKeychainGetStatus(kc,&flags);
  if(getStatus==0&&(flags&kSecUnlockStateStatus))setDefault=ours?0:ensure?SecKeychainSetDefault(kc):errSecNoDefaultKeychain;
 }
 wipe(password.mutableBytes,password.length);
 SecKeychainRef result=NULL;OSStatus copied=SecKeychainCopyDefault(&result);BOOL selected=exactPath(result);if(result)CFRelease(result);
 if(kc)CFRelease(kc);
 BOOL success=open==0&&unlock==0&&getStatus==0&&(flags&kSecUnlockStateStatus)&&setDefault==0&&copied==0&&selected;
 fprintf(stderr,"ACCOUNT15_LOGIN_KEYCHAIN mode=%s secret-created=%d file-created=%d open=%d unlock=%d status=%d unlocked=%d set-default=%d copy-default=%d exact-own-default=%d private-routes=1\n",argv[1],createdSecret,createdFile,(int)open,(int)unlock,(int)getStatus,!!(flags&kSecUnlockStateStatus),(int)setDefault,(int)copied,selected);
 fprintf(stderr,"ACCOUNT15_LOGIN_KEYCHAIN finished=1 status=%d secret-bytes-not-logged=1\n",success?0:1);
 return success?0:1;
}}
