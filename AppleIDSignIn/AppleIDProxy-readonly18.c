// Native first image for a stock macOS 15 WebKit XPC service. Preserve the
// original launchd XPC environment/receive right across one SETEXEC transition.
// Private-cache admission happens while the exact new image is suspended;
// no timed debug-marker child and no singleton Mach-service replacement.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <spawn.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include "macws_webkit_services.h"
#include "macws_macho_arch.h"
#include "macpad-exec-admission.h"
extern char **environ;

// Start only the pinned private guest account session before changing root.
// Child receives no caller account/debug environment or GPU descriptor token.
static int start_private_account_services(void) {
    char *args[]={"/var/jb/usr/bin/python3","/var/jb/usr/macOS/bin/macws_private_account15.py","start",NULL};
    char *env[]={"PATH=/var/jb/usr/bin:/usr/bin:/bin","HOME=/tmp","PYTHONNOUSERSITE=1","PYTHONDONTWRITEBYTECODE=1",NULL};
    pid_t child=0;int error=posix_spawn(&child,args[0],NULL,NULL,args,env);
    if(error){fprintf(stderr,"ACCOUNT15_FRONTDOOR manager-spawn-error=%d\n",error);return 0;}
    int status=0;pid_t result;
    do {result=waitpid(child,&status,0);}while(result<0&&errno==EINTR);
    int ok=result==child&&WIFEXITED(status)&&WEXITSTATUS(status)==0;
    fprintf(stderr,"ACCOUNT15_FRONTDOOR real-backend-start=%d\n",ok);return ok;
}

extern int posix_spawnattr_set_launch_type_np(posix_spawnattr_t *, int);

#include "gpu-exec-producer.inc"
#include "AccountSysctlProducer18.inc"
int main(int argc, char **argv) {
    const char *program = strrchr(argv[0], '/'); program = program ? program+1 : argv[0];
    const char *target="/System/Library/ExtensionKit/Extensions/AppleIDSettings.appex/Contents/MacOS/AppleIDSettings";
    const char *requested=getenv("MACWS_EXTENSION_TARGET");
    if(!requested || strcmp(requested,target))return 64;
    const char *service=getenv("XPC_SERVICE_NAME");
    if(!target || getppid()!=1 || !service || !*service) return 64;
    char log[PATH_MAX];
    snprintf(log,sizeof(log),"/var/jb/var/mobile/settings-pane-appleid15-%s.log",program);
    int fd=open(log,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0600);
    if(fd>=0){if(fchmod(fd,0600)){close(fd);return 1;}dup2(fd,STDERR_FILENO);close(fd);}
    char root[PATH_MAX];
    if(!realpath("/var/mnt/rootfs",root)) {perror("rootfs");return 1;}
    setenv("MACWS_CHROOT_HOST_ROOT",root,1);
    if(geteuid()!=0 || getenv("MACWS_IDENTITY_DIAGNOSTICS") || getenv("MACPAD_ACCOUNT15_REQUIRE_SANDBOX"))return 78;
    if(!start_private_account_services())return 1;
    macpad_issue_gpu_exec_descriptor(root);
    if(!accountSysctlPipe18())return 78;
    if(chroot(root) || chdir("/")) {perror("chroot");return 1;}
    if(setgid(0) || setuid(0)) {perror("service credentials");return 1;}
    fprintf(stderr,"WEBKIT15 credentials uid=%d euid=%d gid=%d egid=%d issetugid=%d\n",getuid(),geteuid(),getgid(),getegid(),issetugid());
    macws_macho_arch_t arch=macws_macho_arch_for_path(target);
    const char *insert=macws_insert_dylib_for_arch(arch);
    if(!insert) {fprintf(stderr,"WEBKIT15 invalid target %s\n",target);return 1;}
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("MACWS_AGX_CRASH_DIAG");

    setenv("DYLD_SHARED_CACHE_DIR","/System/Library/dyld",1);
    setenv("DYLD_SHARED_REGION","private",1);
    setenv("MACWS_PRIVATE_CACHE_LIFECYCLE","1",1);
    setenv("MACWS_PRIVATE_CACHE_DIR","/System/Library/dyld",1);
    setenv("MACPAD_TARGET_MACOS_VERSION","15.6.1",1);
    setenv("HOME","/Users/mobile",1);
    setenv("USER","mobile",1);
    setenv("LOGNAME","mobile",1);
    setenv("MACPAD_PRIVATE_APPLE_ACCOUNT","1",1);
    setenv("MACPAD_ACCOUNT15_FRONTDOOR","v32",1);
    // These root-owned 0700 directories are provisioned by the native15
    // session. confstr must name real chroot-visible directories for WebKit.
    setenv("TMPDIR","/var/folders/zz/macws_uid501/T/",1);
    setenv("MACWS_SESSION_CACHE_DIR","/var/folders/zz/macws_uid501/C/",1);
    setenv("MACWS_SESSION_TEMP_DIR","/var/folders/zz/macws_uid501/T/",1);
    setenv("MACWS_SESSION_USER_DIR","/var/folders/zz/macws_uid501/0/",1);
    if (!strcmp(program,"WebContentProxy")) {
        setenv("MACWS_STEAM_VA_DIAGNOSTICS","1",1);
        setenv("MACPAD_WEBKIT_CAGE8","1",1);
        // Retain Apple's xzone allocator and a coherent Gigacage geometry
        // that can coexist with its fixed arena inside the iPad VA ceiling.

    }
    setenv("MallocNanoZone","0",1);
    if(argc>127)return 64;
    char *arguments[128]; arguments[0]=(char *)target;
    for(int i=1;i<argc;i++)arguments[i]=argv[i]; arguments[argc]=NULL;
    posix_spawnattr_t attr;
    int error=posix_spawnattr_init(&attr);
    if(!error)error=posix_spawnattr_set_launch_type_np(&attr,1);
    if(!error)error=posix_spawnattr_setflags(&attr,POSIX_SPAWN_SETEXEC|POSIX_SPAWN_START_SUSPENDED);
    if(error) {fprintf(stderr,"WEBKIT15 spawn attributes error=%d\n",error);return 1;}
    if(!macpad_arm_native_exec(0)) {fprintf(stderr,"WEBKIT15 admission failed pid=%d\n",getpid());return 1;}
    fprintf(stderr,"WEBKIT15 exact exec armed proxy=%s pid=%d target=%s service=%s\n",program,getpid(),target,service);
    if(setgid(501)||setuid(501)){perror("pane credentials");return 1;}
    setenv("MACWS_APP_EXTENSION","1",1);
    pid_t pid=0;error=posix_spawn(&pid,target,NULL,&attr,arguments,environ);
    macpad_native_rpc("/tmp/exec-jitd.sock","CANCEL\n");
    posix_spawnattr_destroy(&attr);
    fprintf(stderr,"WEBKIT15 exec failed error=%d %s\n",error,strerror(error));return 1;
}
