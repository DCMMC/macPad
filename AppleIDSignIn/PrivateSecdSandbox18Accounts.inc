// Applies the already-qualified real native named sandbox before original secd
// main. Grants only fixed guest storage/resources and three public/private IPC
// lookups. No keybag operation, account reply or policy-query result is replaced.
#include <mach-o/dyld.h>
#include <fcntl.h>
static BOOL privateSecdIsFixture(void){
 if(!getprogname()||strcmp(getprogname(),"secd"))return NO;
 char path[2048];uint32_t size=sizeof(path);if(_NSGetExecutablePath(path,&size))return NO;
 return !strcmp(path,"/usr/local/libexec/macpad-account15/aks-adapt/secd")||!strcmp(path,"/var/mnt/rootfs/usr/local/libexec/macpad-account15/aks-adapt/secd")||!strcmp(path,"/private/var/mnt/rootfs/usr/local/libexec/macpad-account15/aks-adapt/secd");
}
#include "PrivateAKSCompatibility21.inc"
static void applyPrivateSecdSandbox(void){
 if(geteuid()!=501||!privateSecdIsFixture())_exit(78);
 int(*checkPolicy)(pid_t,const char*,int,...)=dlsym(RTLD_DEFAULT,"sandbox_check");
 int(*apply)(const char*,int,void*)=dlsym(RTLD_DEFAULT,"__sandbox_ms");
 char*(*issueFile)(const char*,const char*,unsigned)=dlsym(RTLD_DEFAULT,"sandbox_extension_issue_file");
 char*(*issueMach)(const char*,const char*,unsigned)=dlsym(RTLD_DEFAULT,"sandbox_extension_issue_mach");
 long long(*consume)(const char*)=dlsym(RTLD_DEFAULT,"sandbox_extension_consume");
 if(!checkPolicy||!apply||!issueFile||!issueMach||!consume||checkPolicy(getpid(),NULL,0)!=0)_exit(78);
 const char*rw[]={"/Users/mobile/Library/Keychains","/var/folders/zz/macws_uid501/0/","/var/folders/zz/macws_uid501/T/","/var/folders/zz/macws_uid501/C/"};
 const char*ro[]={"/System/Library","/usr/share","/private/etc/passwd","/private/etc/group","/usr/local/libexec/macpad-account15/aks-adapt/secd"};
 const char*machNames[]={"com.apple.system.notification_center","com.macpad.native15.container.user501.20261018","com.macpad.account15.accountsd.accountmanager"};
 char*tokens[12]={0};
 for(int i=0;i<4;i++){
  struct stat s={0};if(lstat(rw[i],&s)||!S_ISDIR(s.st_mode)||s.st_uid!=501||(s.st_mode&0777)!=0700)_exit(78);
  tokens[i]=issueFile("com.apple.app-sandbox.read-write",rw[i],0);
 }
 for(int i=0;i<5;i++){
  struct stat s={0};if(stat(ro[i],&s)||(i<2?!S_ISDIR(s.st_mode):!S_ISREG(s.st_mode)))_exit(78);
  if(i==4&&(s.st_uid||(s.st_mode&022)))_exit(78);
  tokens[4+i]=issueFile("com.apple.app-sandbox.read",ro[i],0);
 }
 for(int i=0;i<3;i++)tokens[9+i]=issueMach("com.apple.security.exception.mach-lookup.global-name",machNames[i],0);
 for(int i=0;i<12;i++){size_t n=tokens[i]?strnlen(tokens[i],2048):0;if(n<100||n>=2048){fprintf(stderr,"ACCOUNT15_SECD extension-issue-failed resource=%d\n",i);_exit(78);}}
 struct{const char*profile;unsigned long long reserved[2];}request={"temporary-sandbox",{0,0}};
 int applied=apply("Sandbox",1,&request),active=checkPolicy(getpid(),NULL,0);
 fprintf(stderr,"ACCOUNT15_SECD real-sandbox applied=%d active=%d\n",applied,active);
 if(applied||!active)_exit(78);
 for(int i=0;i<12;i++){
  long long handle=consume(tokens[i]);size_t n=strlen(tokens[i]);volatile char*wipe=tokens[i];for(size_t j=0;j<n;j++)wipe[j]=0;free(tokens[i]);
  if(handle<=0){fprintf(stderr,"ACCOUNT15_SECD extension-consume-failed resource=%d\n",i);_exit(78);}
 }
 int outsideWrite=checkPolicy(getpid(),"file-write-create",0x40000001,"/Users/mobile/Library/macpad-secd-outside-policy-probe");
 int accountRead=checkPolicy(getpid(),"file-read-data",0x40000001,"/Users/mobile/Library/Accounts");
 char own[160];snprintf(own,sizeof(own),"/Users/mobile/Library/Keychains/.macpad-secd-admission-%d",getpid());
 int fd=open(own,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW,0600),roundtrip=0;
 if(fd>=0){char value=0;if(write(fd,"1",1)==1&&lseek(fd,0,SEEK_SET)==0&&read(fd,&value,1)==1&&value=='1')roundtrip=1;close(fd);if(unlink(own))roundtrip=0;}
 fprintf(stderr,"ACCOUNT15_SECD storage-roundtrip=%d outside-write-policy=%d outside-account-read-policy=%d\n",roundtrip,outsideWrite,accountRead);
 if(!roundtrip||outsideWrite!=1||accountRead!=1||checkPolicy(getpid(),NULL,0)==0)_exit(78);
 int accountsIPC=checkPolicy(getpid(),"mach-lookup",0x40000002,"com.macpad.account15.accountsd.accountmanager");
 fprintf(stderr,"ACCOUNT15_SECD accountsd-lookup-policy=%d\n",accountsIPC);
 if(accountsIPC)_exit(78);
 installPrivateAKSCompatibility();
 fprintf(stderr,"ACCOUNT15_SECD confined-original-main-next=1 no-account-request-issued=1\n");
}
