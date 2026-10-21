#!/var/jb/usr/bin/python3
"""Opt-in lifecycle for the macOS 15.6.1 guest account services.

Started only by the AppleIDSettings frontdoor; stopped by GUI cleanup. Only fixed own copies/endpoints are managed. Existing
account/keychain data is never removed by stop. Secrets are never command args.
"""
from pathlib import Path
import ctypes,fcntl,hashlib,json,os,plistlib,re,subprocess,sys,time
R=Path('/var/mnt/rootfs');P=Path('/var/jb/var/mobile')
W=R/'var/db/macws/appleid-signin'
T=W/'templates'
PREFIX='com.macpad.account15.session.v31.'
MANIFEST=Path('/var/jb/usr/macOS/libexec/appleid-signin/manifest.json')
def load_manifest():
 st=MANIFEST.lstat()
 if MANIFEST.is_symlink() or st.st_uid or st.st_mode&0o022:
  raise RuntimeError('unowned account runtime manifest')
 return json.loads(MANIFEST.read_text())
manifest=load_manifest()
SPECS=manifest['services']
MODULES=manifest['modules']
lib=ctypes.CDLL('/usr/lib/libproc.dylib')
sb=ctypes.CDLL('/usr/lib/system/libsystem_sandbox.dylib')
def path(pid):
 b=ctypes.create_string_buffer(4096)
 return os.fsdecode(b.value) if pid and lib.proc_pidpath(int(pid),b,len(b))>0 else ''
def query(label):
 p=subprocess.run(['launchctl','print','user/501/'+label],capture_output=True,text=True)
 m=re.search(r'^\s*pid = (\d+)\s*$',p.stdout,re.M)
 return p.returncode,int(m[1]) if m else None,p.stdout
def owned(rec):
 return rec['label'].startswith(PREFIX) and any(rec['path']==os.path.realpath(str(R)+x[2]) for x in SPECS)
def alive(rec):
 # Original helper exits when idle; launchd may restart this same owned job.
 if owned(rec) and rec['kind']=='icloudhelper':
  pid=query(rec['label'])[1]
  if pid and path(pid)==rec['path']:rec['pid']=pid
 return owned(rec) and rec.get('pid') and path(rec['pid'])==rec['path'] and query(rec['label'])[1]==rec['pid']
def store(state):
 p=W/'state.json';stage=W/'state.new'
 fd=os.open(stage,os.O_CREAT|os.O_TRUNC|os.O_WRONLY|os.O_NOFOLLOW,0o600)
 with os.fdopen(fd,'w') as f:json.dump(state,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
 os.replace(stage,p)
def current():
 p=W/'state.json';return json.loads(p.read_text()) if p.exists() else dict(records=[],ready=False)
def stop(state):
 errors=[]
 for rec in reversed(state.get('records',[])):
  if not owned(rec):errors.append('foreign record refused');continue
  ret,pid,_=query(rec['label'])
  if ret==0:
   if pid and path(pid)!=rec['path']:errors.append(rec['kind']+' path mismatch');continue
   subprocess.run(['launchctl','bootout','user/501/'+rec['label']],capture_output=True,timeout=15)
  end=time.monotonic()+8
  while rec.get('pid') and path(rec['pid'])==rec['path'] and time.monotonic()<end:time.sleep(.1)
  if query(rec['label'])[0]==0 or (rec.get('pid') and path(rec['pid'])==rec['path']):errors.append(rec['kind']+' still active')
 state['ready']=False;state['cleanup_errors']=errors;store(state)
 if errors:raise RuntimeError('; '.join(errors))
def logpath(name,session):
 p=W/(session+'-'+name+'.log')
 fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600);os.close(fd);return p
def sanitized(d):
 e=d['EnvironmentVariables']
 assert not e.get('MACWS_IDENTITY_DIAGNOSTICS') and 'MACWS_IDENTITY_DIAGNOSTICS' not in e
 for k in ['MACWS_SUSPEND_AT_EXEC','MACWS_SUSPEND_TARGET','MACPAD_ACCOUNT15_BAA_SELFTEST','MACWS_XPC_NAME_TRACE','MACWS_XPC_NAME_TRACE_FILTER']:e.pop(k,None)
 assert e.get('MACPAD_PRIVATE_APPLE_ACCOUNT')=='1'
 assert e.get('MACPAD_TARGET_MACOS_VERSION')=='15.6.1'
 assert os.path.realpath(e['MACWS_CHROOT_HOST_ROOT'])==os.path.realpath(R)
 d['KeepAlive']=e.get('MACPAD_ACCOUNT15_ROLE')=='icloudhelper';d['RunAtLoad']=True;d['ExitTimeOut']=5
 return d
def unlock(session):
 d=sanitized(plistlib.loads((T/'com.macpad.account15.diagnostic.foundation2.plist').read_bytes()))
 d['Label']=PREFIX+'keychain-unlock'
 assert query(d['Label'])[0]!=0
 args=d['ProgramArguments'];assert args[1:4]==['501','20','/var/mnt/rootfs']
 args[4:] = ['/usr/local/libexec/macpad-account15/PrivateAccountKeychainHelper','ensure']
 e=d['EnvironmentVariables'];e['MACWS_EXTRA_INSERT_LIBRARIES']='/usr/local/lib/PrivateAppleAccount15.dylib';e['MACWS_UTILITY_PROCESS']='1'
 e.pop('MACPAD_ACCOUNT15_REQUIRE_SANDBOX',None)
 d.pop('MachServices',None);d.pop('LaunchEvents',None)
 log=logpath('keychain-unlock',session);d['StandardOutPath']=str(log);d['StandardErrorPath']=str(log)
 job=W/'keychain-unlock.plist';job.write_bytes(plistlib.dumps(d));job.chmod(0o600)
 pid=None;expected=os.path.realpath(str(R)+args[4]);launcher=os.path.realpath(args[0]);passed=False;startupImages=set()
 try:
  subprocess.run(['launchctl','bootstrap','user/501',str(job)],capture_output=True,check=True)
  end=time.monotonic()+20
  while time.monotonic()<end:
   _,p,state=query(d['Label'])
   if p:
    # A published launchd PID is not evidence that SETEXEC has completed.
    # Observe intermediate image names without accepting them as the helper.
    # Only its exact guest image becomes a helper PID used by the checks below.
    image=path(p)
    if image and os.path.basename(image) not in startupImages:
     startupImages.add(os.path.basename(image))
     print('ACCOUNT15_UNLOCK_STARTUP_IMAGE',os.path.basename(image),file=sys.stderr,flush=True)
    if image==expected:pid=p
   terminal=p is None and re.search(r'^\s*state = (not running|exited)\s*$',state,re.M)
   if terminal:
    m=re.search(r'last exit code = (-?\d+)',state)
    passed=bool(m and int(m[1])==0 and 'ACCOUNT15_LOGIN_KEYCHAIN finished=1 status=0' in log.read_text(errors='replace'));break
   time.sleep(.1)
 finally:
  subprocess.run(['launchctl','bootout','user/501/'+d['Label']],capture_output=True,timeout=15)
  end=time.monotonic()+8
  while pid and path(pid) in (launcher,expected) and time.monotonic()<end:time.sleep(.1)
  assert query(d['Label'])[0]!=0 and (not pid or path(pid) not in (launcher,expected))
 assert passed,'Real protected legacy-keychain unlock did not pass'
def verify_images():
 # Preserve genuine bundle metadata required by the original helper.
 assert (R/'usr/local/libexec/macpad-account15/iCloudHelper.xpc/Contents/Info.plist').read_bytes()==(R/'System/Library/PrivateFrameworks/AOSKit.framework/Versions/A/XPCServices/com.apple.iCloudHelper.xpc/Contents/Info.plist').read_bytes()
 # Original LA, service-owner and exact authentication plugins need trust on cold and reused starts.
 # File identities are pinned above; CodeDirectory hashes are read from those files each time.
 sys.path.insert(0,'/var/jb/usr/macOS/bin');import macws_boot_trust as trust
 for f,h in {**MODULES,**{x[2]:x[6] for x in SPECS}}.items():
  p=R/f[1:];assert p.is_file() and not p.is_symlink() and hashlib.sha256(p.read_bytes()).hexdigest()==h,f+' identity changed'
  with p.open('rb') as fd:hashes=trust.code_hashes(fd,os.fstat(fd.fileno()).st_size)
  assert hashes;trust.restore({x['hash'] for x in hashes})
def complete(state):
 rows=state.get('records',[])
 return len(rows)==len(SPECS) and {r['kind'] for r in rows}=={s[0] for s in SPECS} and all(alive(r) for r in rows)
def start():
 verify_images()
 old=current()
 if old.get('ready') and complete(old):
  # The original legacy keychain may auto-lock while these PIDs remain alive.
  # Reuse must perform its real protected-password unlock, not disable locking
  # or treat process liveness as proof that the keychain is still unlocked.
  unlock('reuse-'+str(time.time_ns()))
  return old
 if old.get('records'):stop(old)
 # Refuse concurrent owned diagnostic registrations; do not stop another run.
 for p in P.glob('com.macpad.account15.diagnostic.*.plist'):
  assert query(p.stem)[0]!=0,'Another account diagnostic is registered'
 session=str(time.time_ns());state=dict(session=session,records=[],ready=False,authentication_verified=False)
 try:
  for kind,template,targetPath,uid,gid,sandbox,digest in SPECS:
   if kind=='accountsd':unlock(session)
   d=sanitized(plistlib.loads((T/template).read_bytes()))
   assert d['ProgramArguments'][1:5]==[uid,gid,'/var/mnt/rootfs',targetPath]
   assert d['MachServices'] and all(x.startswith('com.macpad.account15.') for x in d['MachServices'])
   d['Label']=PREFIX+kind;assert query(d['Label'])[0]!=0
   log=logpath(kind,session);d['StandardOutPath']=str(log);d['StandardErrorPath']=str(log)
   job=W/(kind+'.plist');job.write_bytes(plistlib.dumps(d));job.chmod(0o600)
   rec=dict(kind=kind,label=d['Label'],path=os.path.realpath(str(R)+targetPath),pid=None,expected_sandbox=sandbox)
   state['records'].append(rec);store(state)
   subprocess.run(['launchctl','bootstrap','user/501',str(job)],capture_output=True,check=True)
   end=time.monotonic()+12
   while time.monotonic()<end:
    _,pid,_=query(d['Label'])
    if pid and path(pid)==rec['path']:
     rec['pid']=pid
     if sb.sandbox_check(pid,None,0)==sandbox:break
    time.sleep(.1)
   assert alive(rec) and sb.sandbox_check(rec['pid'],None,0)==sandbox,kind+' original runtime state not ready'
   store(state)
  state['ready']=all(alive(x) for x in state['records']);assert state['ready'];store(state);return state
 except BaseException:
  stop(state);raise
def report(state):
 rows=[dict(kind=x['kind'],pid=x.get('pid'),exact_original_pid_alive=bool(alive(x)),native_sandbox=sb.sandbox_check(x['pid'],None,0) if alive(x) else None) for x in state.get('records',[])]
 return dict(ready=bool(state.get('ready') and complete(state)),backends=rows,authentication_verified=False)
if __name__=='__main__':
 assert os.geteuid()==0 and len(sys.argv)==2 and sys.argv[1] in ('start','status','stop')
 assert R.is_dir() and (R/'System/Library/CoreServices/SystemVersion.plist').is_file()
 version=plistlib.loads((R/'System/Library/CoreServices/SystemVersion.plist').read_bytes());assert version['ProductVersion']=='15.6.1'
 W.mkdir(mode=0o700,parents=True,exist_ok=True);assert W.stat().st_uid==0 and not W.is_symlink()
 with (W/'manager.lock').open('a') as lock:
  os.chmod(W/'manager.lock',0o600);fcntl.flock(lock,fcntl.LOCK_EX)
  if sys.argv[1]=='start':state=start()
  elif sys.argv[1]=='stop':state=current();stop(state)
  else:state=current()
  print(json.dumps(report(state),sort_keys=True))
