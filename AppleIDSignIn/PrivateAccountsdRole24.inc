// Original accountsd has no automatic seatbelt profile or main sandbox-init
// call. Preserve that behavior; require the real guest namespace before main.
#include <mach-o/dyld.h>
static BOOL privateAccountsdIsFixture(void){
 if(!getprogname()||strcmp(getprogname(),"accountsd"))return NO;
 char path[2048];uint32_t size=sizeof(path);if(_NSGetExecutablePath(path,&size))return NO;
 return !strcmp(path,"/usr/local/libexec/macpad-account15/accountsd-private/accountsd")||!strcmp(path,"/var/mnt/rootfs/usr/local/libexec/macpad-account15/accountsd-private/accountsd")||!strcmp(path,"/private/var/mnt/rootfs/usr/local/libexec/macpad-account15/accountsd-private/accountsd");
}
static void verifyPrivateAccountsdRole(void){
 if(geteuid()!=501||!privateAccountsdIsFixture()||!getenv("MACPAD_ACCOUNT15_ROLE")||strcmp(getenv("MACPAD_ACCOUNT15_ROLE"),"accountsd"))_exit(78);
 if(![NSHomeDirectory() isEqualToString:@"/Users/mobile"])_exit(78);
 struct stat s={0};if(lstat("/Users/mobile/Library/Accounts",&s)||!S_ISDIR(s.st_mode)||s.st_uid!=501)_exit(78);
 int(*check)(pid_t,const char*,int,...)=dlsym(RTLD_DEFAULT,"sandbox_check");
 fprintf(stderr,"ACCOUNT15_ACCOUNTSD private-namespace-ready=1 home-is-guest=1 original-native-sandbox=%d no-profile-invented=1 no-login-request-issued=1\n",check?check(getpid(),NULL,0):-1);
}
