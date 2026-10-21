#include <dlfcn.h>
#include <sys/stat.h>
static void macpad_issue_gpu_exec_descriptor(const char *root) {
 unsetenv("MACPAD_SETTINGS_GPU_EXEC_FD");
 unsetenv("MACPAD_SETTINGS_GPU_PROBE");
 char probe[PATH_MAX];struct stat probeState={0};
 snprintf(probe,sizeof(probe),"%s/private/var/db/macws/settings-gpu-admission-20261015/probe-once",root);
 if(!lstat(probe,&probeState) && S_ISREG(probeState.st_mode) && probeState.st_uid==0 && (probeState.st_mode&0777)==0600 && probeState.st_size==1 && !unlink(probe))setenv("MACPAD_SETTINGS_GPU_PROBE","1",1);
 char path[PATH_MAX]={0},canonical[PATH_MAX]={0};struct stat state={0};
 if(snprintf(path,sizeof(path),"%s/System/Library/Extensions/AGXMetalG14G.bundle/Contents/MacOS/AGXMetalG14G",root)>=(int)sizeof(path) || !realpath(path,canonical) || strcmp(path,canonical) || stat(canonical,&state) || !S_ISREG(state.st_mode) || state.st_uid!=0 || (state.st_mode&022)) {
  fprintf(stderr,"SETTINGS_GPU_EXEC issuer resource qualification failed\n");return;
 }
 char *(*issue)(const char*,const char*,uint32_t)=dlsym(RTLD_DEFAULT,"sandbox_extension_issue_file");
 char *token=issue?issue("com.apple.sandbox.executable",canonical,0):NULL;
 size_t count=token?strnlen(token,2048):0;int descriptors[2]={-1,-1};int ok=0;
 if(count>100 && count<2048 && !pipe(descriptors)) {
  ssize_t n=write(descriptors[1],token,count);close(descriptors[1]);descriptors[1]=-1;
  if(n==(ssize_t)count && !fcntl(descriptors[0],F_SETFD,0)) {
   char number[32];snprintf(number,sizeof(number),"%d",descriptors[0]);
   if(!setenv("MACPAD_SETTINGS_GPU_EXEC_FD",number,1))ok=1;
  }
 }
 if(!ok && descriptors[0]>=0)close(descriptors[0]);
 if(descriptors[1]>=0)close(descriptors[1]);
 if(token){volatile char *wipe=token;for(size_t i=0;i<count;i++)wipe[i]=0;free(token);}
 fprintf(stderr,"SETTINGS_GPU_EXEC issuer=%d bytes=%lu transport=owned-pipe\n",ok,(unsigned long)count);
}
