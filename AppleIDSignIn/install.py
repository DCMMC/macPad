#!/usr/bin/env python3
"""Install a verified sign-in payload into an existing qualified 24G90 workspace."""
import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path('/var/mnt/rootfs')
STATE = ROOT / 'var/db/macws/appleid-signin'
NATIVE = Path('/var/jb/usr/macOS/libexec/appleid-signin')
PANE = ROOT / 'System/Library/ExtensionKit/Extensions/AppleIDSettings.appex'
ID = 'com.apple.systempreferences.AppleIDSettings'
CARRIER = Path('/var/jb/Applications/MacWSSettingsExtension-' + ID + '.app/SettingsExtensionProxy')
SOURCE = Path('/var/jb/usr/macOS/libexec/settings-carriers-native15') / ID


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def owned(path):
    st = path.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_uid == 0 and not st.st_mode & 0o022,
            'unowned or writable file: ' + str(path))


def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.PIPE, timeout=30)


def allowed(path):
    """Only the account adapter's exact native files and guest destinations."""
    p = Path(path)
    if '..' in p.parts or not p.is_absolute():
        return False
    if p in (CARRIER, SOURCE, Path('/var/jb/usr/macOS/bin/macws_private_account15.py')):
        return True
    if p.parent == NATIVE and p.name in ('AppleIDProxy', 'install.py'):
        return True
    for prefix in (PANE / 'Contents', ROOT / 'usr/local/libexec/macpad-account15',
                   STATE / 'templates'):
        if prefix in p.parents:
            return True
    return p.parent == ROOT / 'usr/local/lib' and p.name in {
        'PrivateAppleAccount15.dylib', 'PrivateAccount15-akd-confined-v23.dylib',
        'PrivateAccount15-secd-aks-v21.dylib', 'PrivateUserSession-v67.dylib',
        'AccountLANamespace18.dylib', 'AccountCTKNamespace18.dylib'}


def replace(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Every parent must already be root-owned. Rootfs itself is the mount point;
    # /var and /var/jb are platform symlinks, so check the resolved parent too.
    parent = path.parent.resolve()
    for node in (parent, *parent.parents):
        st = node.stat()
        require(st.st_uid == 0 and not st.st_mode & 0o022, 'writable install parent: ' + str(node))
    fd, name = tempfile.mkstemp(prefix='.appleid-signin-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chown(name, 0, 0)
        os.chmod(name, mode)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def install(payload):
    require(os.geteuid() == 0, 'run the installer as root on the device')
    require(run('/var/jb/usr/sbin/sysctl', '-n', 'kern.osrelease').strip() == b'22.2.0',
            'this keybag adapter requires the qualified iPadOS 16.2 kernel')
    version = plistlib.loads((ROOT / 'System/Library/CoreServices/SystemVersion.plist').read_bytes())
    require(version['ProductVersion'] == '15.6.1' and version['ProductBuildVersion'] == '24G90',
            'guest version mismatch')
    manifest_file = payload / 'manifest.json'
    owned(manifest_file)
    manifest = json.loads(manifest_file.read_text())
    require(manifest['schema'] == 1 and manifest['build'] == '24G90', 'payload schema mismatch')
    require(len(manifest['services']) == 11, 'incomplete account service closure')
    files = manifest['files']
    for device, row in files.items():
        require(allowed(device), 'foreign install destination: ' + device)
        relative = Path(row['file'])
        require(not relative.is_absolute() and '..' not in relative.parts, 'invalid payload path')
        p = payload / relative
        owned(p)
        require(sha(p) == row['sha256'], 'payload hash mismatch: ' + str(relative))
    owned(CARRIER)
    owned(SOURCE)
    # The account carrier uses the existing native15 exec admission and GPU
    # capability boundary, not the Ventura freestanding proxy.
    for p in (Path('/tmp/exec-jitd.sock'), Path('/tmp/autosignd.sock')):
        require(p.is_socket(), 'native exec-admission service unavailable: ' + p.name)
    for job in manifest['services']:
        label = 'user/501/com.macpad.account15.session.v31.' + job[0]
        require(subprocess.run(['launchctl', 'print', label], capture_output=True).returncode != 0,
                'close the workspace before installing; active account session retained')
    for logical, expected in manifest['modules'].items():
        dest = '/var/mnt/rootfs' + logical
        if dest not in files:
            p = ROOT / logical.lstrip('/')
            owned(p)
            require(sha(p) == expected, 'runtime plugin identity changed: ' + logical)
    jobs = [(payload / row['file']) for path, row in files.items() if '/templates/' in path]
    for path in jobs:
        job = plistlib.loads(path.read_bytes())
        owned(Path(job['ProgramArguments'][0]))
        require(all(k.startswith('com.macpad.account15.') for k in job.get('MachServices', {})),
                'native Mach registration refused')

    hook = Path('/var/jb/usr/macOS/bin/macws_settings_hook.py')
    owned(hook)
    old_hash, new_hash = sha(SOURCE), files[str(SOURCE)]['sha256']
    hook_before = hook.read_bytes()
    require(hook_before.count(old_hash.encode()) == 1, 'qualified carrier pin not found')
    changes = {Path(device): ((payload / row['file']).read_bytes(),
                            0o4755 if Path(device) == CARRIER else
                            0o600 if '/templates/' in device else 0o755)
               for device, row in files.items()}
    changes[hook] = (hook_before.replace(old_hash.encode(), new_hash.encode()), 0o755)
    changes[NATIVE / 'manifest.json'] = (manifest_file.read_bytes(), 0o600)
    sys.path.insert(0, '/var/jb/usr/macOS/bin')
    import macws_boot_trust as trust

    def admit(path):
        with path.open('rb') as f:
            codes = trust.code_hashes(f, os.fstat(f.fileno()).st_size)
        if codes:
            trust.restore({x['hash'] for x in codes})
        return codes

    # Synchronize only the Apple Account carrier's existing registration
    # records. Preserve all other pane registrations and immutable identity.
    carrier_codes = admit(payload / files[str(CARRIER)]['file'])
    cdhash = next(x['hash'] for x in carrier_codes if x['arch'] == 'arm64e')
    marker = PANE / 'Contents/Frameworks/.macws-settings-runtime'
    fields = marker.read_text().strip().split('|')
    require(len(fields) == 9 and fields[0] == 'macws-settings-extension-runtime-v2',
            'qualified Settings runtime marker required')
    fields[5] = cdhash
    changes[marker] = (('|'.join(fields) + '\n').encode(), 0o644)
    changes[CARRIER.parent / '.macws-source-cdhash'] = ((cdhash + '\n').encode(), 0o644)
    registry = ROOT / 'var/db/macws/settings-runtime/carriers-v1.plist'
    data = plistlib.loads(registry.read_bytes())
    data['entries'][ID]['carrier_executable_sha256'] = new_hash
    changes[registry] = (plistlib.dumps(data), 0o644)

    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(STATE.stat().st_uid == 0 and not STATE.is_symlink(), 'unowned state directory')
    with (STATE / 'manager.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        backup = STATE / ('install-' + str(time.time_ns()))
        backup.mkdir(mode=0o700)
        rows = []
        for path in changes:
            entry = {'path': str(path), 'existed': path.exists()}
            if path.exists():
                owned(path)
                saved = backup / str(len(rows))
                saved.write_bytes(path.read_bytes())
                saved.chmod(0o600)
                entry.update(backup=str(saved), mode=stat.S_IMODE(path.stat().st_mode))
            rows.append(entry)
        (backup / 'records.json').write_text(json.dumps(rows, indent=2) + '\n')
        try:
            for path, (contents, mode) in changes.items():
                replace(path, contents, mode)
                admit(path)
            # Verify the exact closure without starting or logging in an account.
            run('/var/jb/usr/bin/python3', '-I', '-c',
                "import runpy; m=runpy.run_path('/var/jb/usr/macOS/bin/macws_private_account15.py', run_name='verify'); m['verify_images']()")
        except BaseException:
            for entry in reversed(rows):
                path = Path(entry['path'])
                if entry['existed']:
                    replace(path, Path(entry['backup']).read_bytes(), entry['mode'])
                    admit(path)
                elif path.exists():
                    path.unlink()
            raise
    print('Apple Account sign-in adapter installed. Account and keychain data retained.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('payload', type=Path)
    args = parser.parse_args()
    install(args.payload.resolve())
