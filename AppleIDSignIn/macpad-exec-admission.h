#pragma once
#include <errno.h>
#include <stdint.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <string.h>
#include <unistd.h>
extern int csops(pid_t,unsigned int,void *,size_t);
// Native launcher boundary: Unix peer identity remains the author autosignd
// contract; exact new exec generation admission belongs to the observer.
static int macpad_native_rpc(const char *path,const char *request) {
 int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return 0;
 struct timeval timeout={2,0};
 if(setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)) ||
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout))) {close(fd);return 0;}
 struct sockaddr_un address={0};address.sun_len=sizeof(address);address.sun_family=AF_UNIX;
 if(strlen(path)>=sizeof(address.sun_path)){close(fd);return 0;}
 strcpy(address.sun_path,path);
 int connected=connect(fd,(void *)&address,sizeof(address))==0;
 size_t length=strlen(request),sent=0,received=0;char reply[3]={0};
 while(connected && sent<length) {
  ssize_t n=write(fd,request+sent,length-sent);
  if(n<0 && errno==EINTR)continue;
  if(n<=0)break;sent+=(size_t)n;
 }
 while(connected && sent==length && received<sizeof(reply)) {
  ssize_t n=read(fd,reply+received,sizeof(reply)-received);
  if(n<0 && errno==EINTR)continue;
  if(n<=0)break;received+=(size_t)n;
 }
 close(fd);return connected && sent==length && received==3 && !memcmp(reply,"OK\n",3);
}
static int macpad_arm_native_exec(int hold) {
 uint32_t flags=0;
 return macpad_native_rpc("/tmp/autosignd.sock","DEBUG\n") &&
        csops(getpid(),0,&flags,sizeof(flags))==0 && (flags&0x10000000) &&
        macpad_native_rpc("/tmp/exec-jitd.sock",hold?"ARM HOLD\n":"ARM\n");
}
