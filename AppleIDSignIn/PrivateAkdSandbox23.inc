// Owned standalone AuthKit candidate only. Native policies are never changed.
#include <mach-o/dyld.h>
#include <fcntl.h>
static BOOL privateAkdIsFixture(void){
 if(!getprogname()||strcmp(getprogname(),"akd"))return NO;
 char path[2048];uint32_t size=sizeof(path);if(_NSGetExecutablePath(path,&size))return NO;
 return !strcmp(path,"/usr/local/libexec/macpad-account15/akd-confined/akd")||!strcmp(path,"/var/mnt/rootfs/usr/local/libexec/macpad-account15/akd-confined/akd")||!strcmp(path,"/private/var/mnt/rootfs/usr/local/libexec/macpad-account15/akd-confined/akd");
}
static void applyPrivateAkdSandbox(void){
 if(geteuid()!=501||!privateAkdIsFixture())_exit(78);
 int(*check)(pid_t,const char*,int,...)=dlsym(RTLD_DEFAULT,"sandbox_check");
 int(*apply)(const char*,int,void*)=dlsym(RTLD_DEFAULT,"__sandbox_ms");
 char*(*file)(const char*,const char*,unsigned)=dlsym(RTLD_DEFAULT,"sandbox_extension_issue_file");
 char*(*mach)(const char*,const char*,unsigned)=dlsym(RTLD_DEFAULT,"sandbox_extension_issue_mach");
 long long(*consume)(const char*)=dlsym(RTLD_DEFAULT,"sandbox_extension_consume");
 if(!check||!apply||!file||!mach||!consume||check(getpid(),NULL,0)!=0)_exit(78);
 const char*rw[]={"/var/folders/zz/macws_uid501/0/","/var/folders/zz/macws_uid501/T/","/var/folders/zz/macws_uid501/C/","/Users/mobile/Library/AuthKit","/Users/mobile/Library/Caches/com.apple.akd","/Users/mobile/Library/HTTPStorages/com.apple.akd"};
 const char*ro[]={"/System/Library","/usr/share","/private/etc/passwd","/private/etc/group","/usr/local/libexec/macpad-account15/akd-confined/akd"};
 // Sign-in finalization uses private follow-up and CDP endpoints.
 // BAA obtains the real device DCRT through native mobileactivationd.
 // Grant lookup to that endpoint; preserve its original identity operations.
 // Security must evaluate trust through the existing genuine macOS trustd
 // peers, including the user agent selected by the corrected Aqua session.
 const char*ipc[]={"com.apple.system.notification_center","com.macpad.native15.container.user501.20261018","com.apple.macosbooter.cfprefsd.agent.501","com.apple.macosbooter.host.control","com.apple.mDNSResponder","com.macpad.account15.securityd.xpc","com.macpad.account15.accountsd.accountmanager","com.macpad.account15.ak.anisette.xpc","com.macpad.account15.corefollowup.agent","com.macpad.account15.cdp.daemon","com.apple.mobileactivationd","com.macpad.main15.trustd.20261005","com.macpad.main15.trustd.agent.20261005"};
 char*tokens[24]={0};
 for(int i=0;i<6;i++){
  struct stat s={0};if(lstat(rw[i],&s)||!S_ISDIR(s.st_mode)||s.st_uid!=501||(s.st_mode&0777)!=0700)_exit(78);
  tokens[i]=file("com.apple.app-sandbox.read-write",rw[i],0);
 }
 for(int i=0;i<5;i++)tokens[6+i]=file("com.apple.app-sandbox.read",ro[i],0);
 for(int i=0;i<13;i++)tokens[11+i]=mach("com.apple.security.exception.mach-lookup.global-name",ipc[i],0);
 for(int i=0;i<24;i++){size_t n=tokens[i]?strnlen(tokens[i],2048):0;if(n<100||n>=2048){fprintf(stderr,"ACCOUNT15_AKD token-issue-failed index=%d\n",i);_exit(78);}}
 struct{const char*profile;unsigned long long reserved[2];}request={"akd",{0,0}};
 errno=0;int result=apply("Sandbox",1,&request),saved=errno,active=check(getpid(),NULL,0);
 fprintf(stderr,"ACCOUNT15_AKD real-profile=akd applied=%d errno=%d active=%d\n",result,saved,active);
 if(result||!active)_exit(78);
 for(int i=0;i<24;i++){
  long long handle=consume(tokens[i]);size_t n=strlen(tokens[i]);volatile char*wipe=tokens[i];for(size_t j=0;j<n;j++)wipe[j]=0;free(tokens[i]);
  if(handle<=0){fprintf(stderr,"ACCOUNT15_AKD token-consume-failed index=%d\n",i);_exit(78);}
 }
 int outside=check(getpid(),"file-write-create",0x40000001,"/Users/mobile/Library/macpad-akd-outside-policy-probe");
 int accounts=check(getpid(),"file-read-data",0x40000001,"/Users/mobile/Library/Accounts");
 char own[180];snprintf(own,sizeof(own),"/Users/mobile/Library/AuthKit/.macpad-akd-admission-%d",getpid());
 int fd=open(own,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW,0600),ok=0;
 if(fd>=0){char b=0;if(write(fd,"1",1)==1&&lseek(fd,0,SEEK_SET)==0&&read(fd,&b,1)==1&&b=='1')ok=1;close(fd);if(unlink(own))ok=0;}
 fprintf(stderr,"ACCOUNT15_AKD storage-roundtrip=%d outside-write-policy=%d outside-accounts-read-policy=%d\n",ok,outside,accounts);
 if(!ok||outside!=1||accounts!=1||!check(getpid(),NULL,0))_exit(78);
 fprintf(stderr,"ACCOUNT15_AKD confined-original-main-next=1 no-login-request-issued=1\n");
}
