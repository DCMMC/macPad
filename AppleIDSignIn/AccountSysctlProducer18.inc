// Native owned launcher only: one read-only capability crosses the existing
// SETEXEC exclusively in an anonymous pipe. A pre-exec PID-bound token becomes
// invalid on exec (verified by SysctlExecProbe18). Never use args/logs/files.
#include <dlfcn.h>
static int accountSysctlPipe18(void) {
 unsetenv("MACPAD_ACCOUNT15_SYSCTL_FD");
 char *(*issue)(const char*,unsigned)=dlsym(RTLD_DEFAULT,"sandbox_extension_issue_generic");
 char *cap=issue?issue("com.apple.security.exception.sysctl.read-only",0):NULL;
 size_t size=cap?strnlen(cap,2048):0;int fds[2]={-1,-1},ok=0;
 if(size>100&&size<2048&&!pipe(fds)) {
  ssize_t written=write(fds[1],cap,size);close(fds[1]);fds[1]=-1;
  if(written==(ssize_t)size&&!fcntl(fds[0],F_SETFD,0)) {
   char number[24];snprintf(number,sizeof(number),"%d",fds[0]);
   ok=!setenv("MACPAD_ACCOUNT15_SYSCTL_FD",number,1);
  }
 }
 if(!ok&&fds[0]>=0)close(fds[0]);
 if(fds[1]>=0)close(fds[1]);
 if(cap){volatile char *wipe=cap;for(size_t i=0;i<size;i++)wipe[i]=0;free(cap);}
 fprintf(stderr,"ACCOUNT15_SYSCTL18 issued=%d owned-pipe=1 read-only=1\n",ok);
 return ok;
}
