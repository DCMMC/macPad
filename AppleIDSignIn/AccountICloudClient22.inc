// Included only by the guarded guest pane and accountsd namespace modules.
// AOSKit connect (IDA/Hopper 0x1ae29aa54) uses bundled XPC, not Mach XPC.
static xpc_connection_t (*icloud22OriginalCreate)(const char *,dispatch_queue_t);
static xpc_connection_t icloud22Create(const char *name,dispatch_queue_t queue) {
 if(enabled && name && !strcmp(name,"com.apple.iCloudHelper")) {
  fprintf(stderr,"ACCOUNT15_ICLOUD22 client-route pid=%d\n",getpid());
  return xpc_connection_create_mach_service("com.macpad.account15.iCloudHelper",queue,0);
 }
 return icloud22OriginalCreate(name,queue);
}
static void installICloudClient22(void) {
 void *(*image)(const char*)=dlsym(RTLD_DEFAULT,"MSGetImageByName");
 void *(*symbol)(void*,const char*)=dlsym(RTLD_DEFAULT,"MSFindSymbol");
 void (*hook)(void*,void*,void**)=dlsym(RTLD_DEFAULT,"MSHookFunction");
 void *x=image?image("/usr/lib/system/libxpc.dylib"):NULL;
 void *entry=x&&symbol?symbol(x,"_xpc_connection_create"):NULL;
 if(!entry||!hook)_exit(78);
 hook(entry,(void*)icloud22Create,(void**)&icloud22OriginalCreate);
 if(!icloud22OriginalCreate)_exit(78);
 fprintf(stderr,"ACCOUNT15_ICLOUD22 client-installed pid=%d\n",getpid());
}
