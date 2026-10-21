// Preserve original main's timer and original peer/message/audit validation.
// Only the service-launch transport differs in this private guest instance.
#include <mach-o/dyld.h>
#include <CoreFoundation/CoreFoundation.h>
static void (*icloud22OriginalMain)(xpc_connection_handler_t);
static void icloud22Main(xpc_connection_handler_t handler) {
 if(!handler)_exit(78);
 xpc_connection_t listener=xpc_connection_create_mach_service(
  "com.macpad.account15.iCloudHelper",dispatch_get_main_queue(),
  XPC_CONNECTION_MACH_SERVICE_LISTENER);
 if(!listener)_exit(78);
 xpc_connection_set_event_handler(listener,^(xpc_object_t event){
  if(xpc_get_type(event)==XPC_TYPE_CONNECTION) {
   fprintf(stderr,"ACCOUNT15_ICLOUD22 peer pid=%d uid=%u\n",xpc_connection_get_pid(event),xpc_connection_get_euid(event));
   handler(event);
  } else fprintf(stderr,"ACCOUNT15_ICLOUD22 listener-event type=%s\n",xpc_get_type(event)==XPC_TYPE_ERROR?"error":"other");
 });
 xpc_connection_resume(listener);
 fprintf(stderr,"ACCOUNT15_ICLOUD22 listener-ready original-handler=1 uid=%d\n",getuid());
 // Original bundle requests NSRunLoop. Keep its main run loop serviced,
 // including the main dispatch queue, without invoking unmanaged xpc_main.
 CFRunLoopTimerRef keep=CFRunLoopTimerCreateWithHandler(NULL,CFAbsoluteTimeGetCurrent()+3600,3600,0,0,^(CFRunLoopTimerRef t){});
 CFRunLoopAddTimer(CFRunLoopGetMain(),keep,kCFRunLoopCommonModes);
 CFRunLoopRun();
 _exit(78);
}
static void verifyICloudHelper22(void) {
 char path[2048]={0};uint32_t n=sizeof(path);
 const char *expected="/usr/local/libexec/macpad-account15/iCloudHelper.xpc/Contents/MacOS/com.apple.iCloudHelper";
 if(_NSGetExecutablePath(path,&n)||strcmp(path,expected)||getuid()!=501||geteuid()!=501
  ||!getenv("MACPAD_ACCOUNT15_ROLE")||strcmp(getenv("MACPAD_ACCOUNT15_ROLE"),"icloudhelper")
  ||!getenv("HOME")||strcmp(getenv("HOME"),"/Users/mobile")
  ||![NSHomeDirectory() isEqualToString:@"/Users/mobile"]
  ||getenv("MACPAD_ACCOUNT15_REQUIRE_SANDBOX"))_exit(78);
 if(![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.iCloudHelper"])_exit(78);
}
static void installICloudHelper22(void) {
 void *(*image)(const char*)=dlsym(RTLD_DEFAULT,"MSGetImageByName");
 void *(*symbol)(void*,const char*)=dlsym(RTLD_DEFAULT,"MSFindSymbol");
 void (*hook)(void*,void*,void**)=dlsym(RTLD_DEFAULT,"MSHookFunction");
 void *x=image?image("/usr/lib/system/libxpc.dylib"):NULL;
 void *entry=x&&symbol?symbol(x,"_xpc_main"):NULL;
 if(!entry||!hook)_exit(78);
 hook(entry,(void*)icloud22Main,(void**)&icloud22OriginalMain);
 if(!icloud22OriginalMain)_exit(78);
 fprintf(stderr,"ACCOUNT15_ICLOUD22 server-installed original-validation=1 pid=%d\n",getpid());
}
