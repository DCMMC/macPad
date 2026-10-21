// The exact guest pane guard in the enclosing constructor is required.
// The original server workflow took 38 s to finish loading while its UI timer
// failed at 30 s. Keep all original failure/cancel/ready paths, with a bounded
// 90 s UI wait for the original default interval only.
#include <time.h>
#include <objc/message.h>
static unsigned web22Count;
static double web22Now(void) { struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return ts.tv_sec+ts.tv_nsec/1e9; }
static void web22Log(NSString *stage,NSDictionary *details) {
 if(__atomic_fetch_add(&web22Count,1,__ATOMIC_RELAXED)>=512)return;
 NSMutableDictionary *d=[NSMutableDictionary dictionaryWithDictionary:details?:@{}];
 d[@"event"]=stage;d[@"time"]=@(web22Now());d[@"pid"]=@(getpid());
 NSData *data=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
 if(data)fprintf(stderr,"ACCOUNT15_WEB22 %.*s\n",(int)data.length,(const char*)data.bytes);
}
static NSDictionary *web22URL(NSURL *u) {
 return @{@"host":u.host?:@"",@"path":u.path?:@""};
}
static void (*web22Timer)(id,SEL,double);
static void web22CreateTimer(id o,SEL s,double value) {
 double use=value==30.0?90.0:value;
 web22Log(@"timer-create",@{@"original":@(value),@"effective":@(use)});
 web22Timer(o,s,use);
}
static id (*web22Request)(id,SEL,id,id,id,id,id);
static id web22WillSend(id o,SEL s,id view,id resource,NSURLRequest *request,id redirect,id source) {
 double start=web22Now();
 NSMutableDictionary *d=[NSMutableDictionary dictionaryWithDictionary:web22URL(request.URL)];
 d[@"resource"]=[NSString stringWithFormat:@"%p",resource];web22Log(@"resource-start",d);
 id result=web22Request(o,s,view,resource,request,redirect,source);
 d[@"signing_seconds"]=@(web22Now()-start);web22Log(@"resource-signed",d);
 return result;
}
static void (*web22Response)(id,SEL,id,id,id,id);
static void web22DidReceive(id o,SEL s,id view,id resource,NSURLResponse *response,id source) {
 NSMutableDictionary *d=[NSMutableDictionary dictionaryWithDictionary:web22URL(response.URL)];
 d[@"resource"]=[NSString stringWithFormat:@"%p",resource];
 d[@"http"]=@([response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse*)response statusCode]:0);
 d[@"length"]=@(response.expectedContentLength);web22Log(@"resource-response",d);
 web22Response(o,s,view,resource,response,source);
}
static void (*web22Frame)(id,SEL,id,id);
static void web22DidFinish(id o,SEL s,id view,id frame) {
 web22Log(@"frame-finished",@{});web22Frame(o,s,view,frame);
}
static void (*web22Ready)(id,SEL),(*web22Loaded)(id,SEL),(*web22Destroy)(id,SEL);
// In this guest the inherited layer-backed legacy WebHTMLView can remain blank
// after its parent is unhidden. Runtime A/B: DOM/layout/style were visible and
// valid, and invalidating + displaying these existing views exposed the real
// phone-verification form. Use normal AppKit invalidation after the original
// readiness transition. Never invoke the lazy webView getter (it reloads UI).
static unsigned web22RedrawTree(id view,unsigned depth) {
 if(!view||depth>24)return 0;
 Class nsview=objc_getClass("NSView");if(![view isKindOfClass:nsview])return 0;
 unsigned count=0;
 if([view isKindOfClass:objc_getClass("WebView")]||[view isKindOfClass:objc_getClass("WebHTMLView")]){
  ((void(*)(id,SEL,BOOL))objc_msgSend)(view,sel_registerName("setNeedsDisplay:"),YES);
  ((void(*)(id,SEL))objc_msgSend)(view,sel_registerName("displayIfNeeded"));count++;
 }
 NSArray *children=((id(*)(id,SEL))objc_msgSend)(view,sel_registerName("subviews"));
 for(id child in children)count+=web22RedrawTree(child,depth+1);
 return count;
}
static void web22IsReady(id o,SEL s){
 web22Log(@"js-client-ready",@{});web22Ready(o,s);
 dispatch_async(dispatch_get_main_queue(),^{
  id root=((id(*)(id,SEL))objc_msgSend)(o,sel_registerName("containerView"));
  web22Log(@"ready-redraw",@{@"views":@(web22RedrawTree(root,0))});
 });
}
static void web22HasLoaded(id o,SEL s){web22Log(@"js-client-loaded",@{});web22Loaded(o,s);}
static void web22DestroyTimer(id o,SEL s){web22Log(@"timer-destroy",@{});web22Destroy(o,s);}
static void (*web22Fire)(id,SEL,id);
static void web22FireTimer(id o,SEL s,id timer){web22Log(@"timer-fired",@{@"stack":[NSThread callStackSymbols]});web22Fire(o,s,timer);}
static void (*web22Fail)(id,SEL,id);
static void web22Failed(id o,SEL s,NSError *err){
 web22Log(@"web-failed",@{@"domain":err.domain?:@"",@"code":@(err.code),@"stack":[NSThread callStackSymbols]});web22Fail(o,s,err);
}
static void installAuthWeb22(void) {
 struct Entry {const char *cls,*sel;unsigned argc;IMP replacement;void **original;} entries[]={
  {"AKAuthWebTabView","_createWaitTimerWithTimeInternval:",3,(IMP)web22CreateTimer,(void**)&web22Timer},
  {"AKWebKitController","webView:resource:willSendRequest:redirectResponse:fromDataSource:",7,(IMP)web22WillSend,(void**)&web22Request},
  {"AKWebKitController","webView:resource:didReceiveResponse:fromDataSource:",6,(IMP)web22DidReceive,(void**)&web22Response},
  {"AKWebKitController","webView:didFinishLoadForFrame:",4,(IMP)web22DidFinish,(void**)&web22Frame},
  {"AKAuthWebTabView","icaWebKitViewIsAvailable",2,(IMP)web22IsReady,(void**)&web22Ready},
  {"AKAuthWebTabView","icaWebKitViewHasLoaded",2,(IMP)web22HasLoaded,(void**)&web22Loaded},
  {"AKAuthWebTabView","_destroyWaitTimer",2,(IMP)web22DestroyTimer,(void**)&web22Destroy},
  {"AKAuthWebTabView","_fireWaitTimer:",3,(IMP)web22FireTimer,(void**)&web22Fire},
  {"AKAuthWebTabView","webviewFailedWithError:",3,(IMP)web22Failed,(void**)&web22Fail},
 };
 Method methods[sizeof(entries)/sizeof(entries[0])];
 for(unsigned i=0;i<sizeof(entries)/sizeof(entries[0]);i++){
  methods[i]=class_getInstanceMethod(objc_getClass(entries[i].cls),sel_registerName(entries[i].sel));
  Dl_info info={0};
  if(!methods[i]||method_getNumberOfArguments(methods[i])!=entries[i].argc||!dladdr((void*)method_getImplementation(methods[i]),&info)||!info.dli_fname||!strstr(info.dli_fname,"/AuthKitUI.framework/")){
   web22Log(@"installation-skipped",@{@"index":@(i)});return;
  }
 }
 char type[16]={0};method_getArgumentType(methods[0],2,type,sizeof(type));
 if(strcmp(type,"d")){web22Log(@"installation-skipped",@{@"reason":@"timer ABI"});return;}
 for(unsigned i=0;i<sizeof(entries)/sizeof(entries[0]);i++)*entries[i].original=(void*)method_setImplementation(methods[i],entries[i].replacement);
 web22Log(@"installed",@{@"wait_seconds":@90,@"original_callbacks":@YES});
}
