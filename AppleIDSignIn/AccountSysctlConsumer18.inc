// Called only after all existing exact-pane, UID501, HOME and guest guards.
// Native sysctl read-only extension covers read queries, not a single key.
#include <fcntl.h>
#include <limits.h>
#include <sys/sysctl.h>
static void installAccountSysctl18(void) {
 const char *number=getenv("MACPAD_ACCOUNT15_SYSCTL_FD");char *end=NULL;
 long value=number?strtol(number,&end,10):-1;
 int valid=number&&*number&&end&&!*end&&value>2&&value<=INT_MAX;
 unsetenv("MACPAD_ACCOUNT15_SYSCTL_FD");
 if(!valid){fprintf(stderr,"ACCOUNT15_SYSCTL18 descriptor-missing=1\n");_exit(78);}
 int fd=(int)value;struct stat state={0};char cap[2048]={0};ssize_t size=-1;
 // Darwin reports an anonymous pipe's UID using the inspecting credentials;
 // it does not retain the creator's UID across this root-to-501 transition.
 if(!fstat(fd,&state)&&S_ISFIFO(state.st_mode)) {
  int flags=fcntl(fd,F_GETFL);if(flags>=0&&!fcntl(fd,F_SETFL,flags|O_NONBLOCK))size=read(fd,cap,sizeof(cap)-1);
 }
 close(fd);
 long long(*consume)(const char*)=dlsym(RTLD_DEFAULT,"sandbox_extension_consume");
 int(*check)(pid_t,const char*,int,...)=dlsym(RTLD_DEFAULT,"sandbox_check");
 errno=0;long long handle=(size>100&&size<2048&&consume)?consume(cap):-1;int consumeError=errno;
 for(size_t i=0;i<sizeof(cap);i++)((volatile char*)cap)[i]=0;
 int revision=0;size_t length=sizeof(revision);
 int query=sysctlbyname("kern.osrevision",&revision,&length,NULL,0);
 int active=check?check(getpid(),NULL,0):-1;
 fprintf(stderr,"ACCOUNT15_SYSCTL18 consumed=%d query-status=%d sandbox=%d pipe-valid=%d size-valid=%d consume-error=%d\n",handle>0,query,active,S_ISFIFO(state.st_mode),size>100&&size<2048,consumeError);
 if(handle<=0||query||active<0)_exit(78);
}
