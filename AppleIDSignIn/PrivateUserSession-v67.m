// Guest akd LaunchAgent session adapter. No account/keychain/crypto API hooks.
// The 24G90 LaunchAgent explicitly belongs to Aqua; outer iOS launchd reports
// System. Translate only that successful read for this exact private guest copy.
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string.h>
static void reject(unsigned stage){fprintf(stderr,"ACCOUNT15_USER_SESSION v67 guard-rejected=%u\n",stage);_exit(78);}
static void*(*originalSwap)(void*,int,const char*,char**);
static void*userSession(void*p,int key,const char*input,char**output){
 void*error=originalSwap(p,key,input,output);
 if(!error&&key==6&&!input&&output&&*output&&!strcmp(*output,"System")){
  char*a=strdup("Aqua");if(a){free(*output);*output=a;}
 }
 return error;
}
__attribute__((constructor))static void install(void){
 const char*r=getenv("MACWS_CHROOT_HOST_ROOT"),*v=getenv("MACPAD_TARGET_MACOS_VERSION"),*o=getenv("MACPAD_PRIVATE_APPLE_ACCOUNT"),*role=getenv("MACPAD_ACCOUNT15_USER_SESSION"),*h=getenv("HOME");
 if(getuid()!=501||geteuid()!=501||strcmp(getprogname(),"akd")||!r||(strcmp(r,"/var/mnt/rootfs")&&strcmp(r,"/private/var/mnt/rootfs"))||!v||strcmp(v,"15.6.1")||!o||strcmp(o,"1")||!role||strcmp(role,"Aqua")||!h||strcmp(h,"/Users/mobile")||getenv("MACWS_IDENTITY_DIAGNOSTICS"))reject(1);
 char executable[1024];uint32_t count=sizeof(executable);
 if(_NSGetExecutablePath(executable,&count)||(strcmp(executable,"/usr/local/libexec/macpad-account15/akd-confined/akd")&&strcmp(executable,"/var/mnt/rootfs/usr/local/libexec/macpad-account15/akd-confined/akd")&&strcmp(executable,"/private/var/mnt/rootfs/usr/local/libexec/macpad-account15/akd-confined/akd")))reject(2);
 const unsigned char uuid[16]={0xf9,0x08,0x13,0xda,0x45,0x38,0x38,0x33,0xa5,0x69,0xa5,0x9c,0x72,0x72,0x61,0x35};
 BOOL exact=NO;unsigned mainImages=0;uint32_t imageCount=_dyld_image_count();if(imageCount>4096)reject(3);
 for(uint32_t i=0;i<imageCount;i++){
  const struct mach_header_64*mh=(const void*)_dyld_get_image_header(i);
  if(!mh||mh->magic!=MH_MAGIC_64||mh->filetype!=MH_EXECUTE)continue;
  mainImages++;if(mh->ncmds>1024)reject(3);
  const char*p=(const char*)(mh+1),*end=p+mh->sizeofcmds;
  for(unsigned j=0;j<mh->ncmds;j++){
   const struct load_command*c=(const void*)p;if(p+sizeof(*c)>end||c->cmdsize<sizeof(*c)||p+c->cmdsize>end)reject(4);
   if(c->cmd==LC_UUID&&c->cmdsize>=sizeof(struct uuid_command))exact=exact||!memcmp(((const struct uuid_command*)c)->uuid,uuid,16);
   p+=c->cmdsize;
  }
 }
 if(!exact){fprintf(stderr,"ACCOUNT15_USER_SESSION v67 image-scan-main-count=%u\n",mainImages);reject(5);}
 void*(*image)(const char*)=dlsym(RTLD_DEFAULT,"MSGetImageByName");
 void*(*symbol)(void*,const char*)=dlsym(RTLD_DEFAULT,"MSFindSymbol");
 void(*hook)(void*,void*,void**)=dlsym(RTLD_DEFAULT,"MSHookFunction");
 void*m=image?image("/usr/lib/system/libxpc.dylib"):NULL;
 void*t=m&&symbol?symbol(m,"_vproc_swap_string"):NULL;
 if(!t||!hook)reject(6);
 hook(t,(void*)userSession,(void**)&originalSwap);
 if(!originalSwap)reject(7);
 char*actual=NULL;void*error=userSession(NULL,6,NULL,&actual);
 BOOL aqua=!error&&actual&&!strcmp(actual,"Aqua");free(actual);
 if(!aqua)reject(8);
 fprintf(stderr,"ACCOUNT15_USER_SESSION v67 exact-private-akd=1 guest-agent-aqua=1 original-errors-preserved=1\n");
}
