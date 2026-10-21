// Exact guest-secd/iPadOS16.2 compatibility candidate. Translates only macOS's
// unavailable user-only bag selector(-3) to the real device bag selector(0).
// Encryption class, input/output buffers, real errors and API results preserved.
// Never map to Security's KEYBAG_NONE(-1), fabricate success, or change a keybag.
#include <sys/sysctl.h>
static int(*privateRealAKSSystem)(int,int*);
static int(*privateRealAKSLock)(int,unsigned*);
static int(*privateRealAKSWrap)(const void*,int,int,int,void*,int*,int*);
static int(*privateRealAKSUnwrap)(const void*,int,int,int,void*,int*);
static int privateAKSBag(int bag){return bag==-3?0:bag;}
static int privateAKSSystem(int bag,int*out){return privateRealAKSSystem(privateAKSBag(bag),out);}
static int privateAKSLock(int bag,unsigned*out){return privateRealAKSLock(privateAKSBag(bag),out);}
static int privateAKSWrap(const void*in,int n,int cls,int bag,void*out,int*len,int*actual){return privateRealAKSWrap(in,n,cls,privateAKSBag(bag),out,len,actual);}
static int privateAKSUnwrap(const void*in,int n,int cls,int bag,void*out,int*len){return privateRealAKSUnwrap(in,n,cls,privateAKSBag(bag),out,len);}
static void installPrivateAKSCompatibility(void){
 if(!privateSecdIsFixture()||geteuid()!=501||!getenv("MACPAD_ACCOUNT15_AKS_COMPAT")||strcmp(getenv("MACPAD_ACCOUNT15_AKS_COMPAT"),"v1"))_exit(78);
 char kernel[64]={0};size_t length=sizeof(kernel);
 if(sysctlbyname("kern.osrelease",kernel,&length,NULL,0)||strcmp(kernel,"22.2.0"))_exit(78);
 int uuidMatches=0;const unsigned char expected[16]={0x33,0xf3,0x45,0x2c,0x10,0x02,0x3d,0xe6,0x8d,0x60,0x88,0x87,0xb9,0xfe,0x6e,0xc3};
 for(uint32_t i=0;i<_dyld_image_count();i++){
  const char*name=_dyld_get_image_name(i);if(!name||!strstr(name,"/AppleKeyStore.framework/"))continue;
  const struct mach_header_64*h=(const void*)_dyld_get_image_header(i);if(!h||h->magic!=MH_MAGIC_64||h->ncmds>1024)_exit(78);
  const char*p=(const char*)(h+1),*end=p+h->sizeofcmds;
  for(unsigned j=0;j<h->ncmds;j++){
   const struct load_command*c=(const void*)p;if(p+sizeof(*c)>end||c->cmdsize<sizeof(*c)||p+c->cmdsize>end)_exit(78);
   if(c->cmd==LC_UUID&&c->cmdsize>=sizeof(struct uuid_command))uuidMatches=!memcmp(((const struct uuid_command*)c)->uuid,expected,16);
   p+=c->cmdsize;
  }
 }
 if(!uuidMatches)_exit(78);
 void*(*image)(const char*)=dlsym(RTLD_DEFAULT,"MSGetImageByName");
 void*(*symbol)(void*,const char*)=dlsym(RTLD_DEFAULT,"MSFindSymbol");
 void(*hook)(void*,void*,void**)=dlsym(RTLD_DEFAULT,"MSHookFunction");
 void*m=image?image("/System/Library/PrivateFrameworks/AppleKeyStore.framework/Versions/A/AppleKeyStore"):NULL;
 const char*names[]={"_aks_get_system","_aks_get_lock_state","_aks_wrap_key","_aks_unwrap_key"};
 void*replacement[]={(void*)privateAKSSystem,(void*)privateAKSLock,(void*)privateAKSWrap,(void*)privateAKSUnwrap};
 void**original[]={(void**)&privateRealAKSSystem,(void**)&privateRealAKSLock,(void**)&privateRealAKSWrap,(void**)&privateRealAKSUnwrap};
 void*target[4]={0};if(!m||!symbol||!hook)_exit(78);
 for(int i=0;i<4;i++){target[i]=symbol(m,names[i]);if(!target[i])_exit(78);}
 for(int i=0;i<4;i++)hook(target[i],replacement[i],original[i]);
 fprintf(stderr,"ACCOUNT15_AKS_COMPAT installed exact-image=1 bag-minus3-to-device0=1 real-return-preserved=1 class-unchanged=1\n");
}
