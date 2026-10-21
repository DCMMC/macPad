#!/usr/bin/env python3
"""Build the opt-in Apple Account adapter from source and a 24G90 guest rootfs."""
import argparse
import hashlib
import json
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

from macho import parse, thin

B = Path(__file__).resolve().parent
PANE = '/System/Library/ExtensionKit/Extensions/AppleIDSettings.appex'
LIB = '/usr/local/lib/'
NATIVE = '/var/jb/usr/macOS/libexec/appleid-signin'
MODULES = [
    ('PrivateAppleAccount15.v16.m', LIB + 'PrivateAppleAccount15.dylib'),
    ('PrivateAccount15-frontdoor-web22.m', PANE + '/Contents/Frameworks/PrivateAccount15-frontdoor-v32.dylib'),
    ('PrivateAccount15.accountsd-helper22.m', '/usr/local/libexec/macpad-account15/accountsd-private/ns'),
    ('PrivateAccount15.icloudhelper22.m', '/usr/local/libexec/macpad-account15/iCloudHelper.xpc/Contents/MacOS/ns'),
    ('PrivateAccount15.akd-confined-v23.apsfix11.m', LIB + 'PrivateAccount15-akd-confined-v23.dylib'),
    ('PrivateAccount15.secd-aks-v21.accounts18.m', LIB + 'PrivateAccount15-secd-aks-v21.dylib'),
    ('PrivateUserSession-v67.m', LIB + 'PrivateUserSession-v67.dylib'),
    ('AccountLANamespace18.m', LIB + 'AccountLANamespace18.dylib'),
    ('AccountCTKNamespace18.m', LIB + 'AccountCTKNamespace18.dylib'),
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.PIPE)


def arm64e(data):
    parts = [x for x in thin(data) if parse(x) and parse(x)['cpu'] == 0x100000c
             and parse(x)['subtype'] & 0xffffff == 2]
    require(len(parts) == 1, 'expected one arm64e slice')
    return parts[0]


def append(data, names):
    """Add load edges in zero header padding; never move or change sections."""
    before = parse(data)
    require(before and data[:4] == b'\xcf\xfa\xed\xfe', 'expected 64-bit Mach-O')
    existing = {x['name'] for x in before['dependencies']}
    names = [n for n in names if n not in existing]
    count, size = struct.unpack_from('<II', data, 16)
    off, first = 32, len(data)
    require(32 + size <= len(data), 'invalid load-command size')
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, off)
        require(length >= 8 and off + length <= 32 + size, 'invalid load command')
        if cmd == 0x19:
            nsections = struct.unpack_from('<I', data, off + 64)[0]
            require(72 + nsections * 80 <= length, 'invalid section table')
            for i in range(nsections):
                fo = struct.unpack_from('<I', data, off + 72 + i * 80 + 48)[0]
                if fo:
                    first = min(first, fo)
        off += length
    require(off == 32 + size, 'load-command boundary mismatch')
    extra = b''
    for name in names:
        raw = name.encode() + b'\0'
        length = (24 + len(raw) + 7) & ~7
        extra += struct.pack('<6I', 0xc, length, 24, 0, 0, 0) + raw
        extra += bytes(length - 24 - len(raw))
    require(off + len(extra) <= first and not any(data[off:off + len(extra)]),
            'insufficient zero header padding')
    result = bytearray(data)
    result[off:off + len(extra)] = extra
    struct.pack_into('<II', result, 16, count + len(names), size + len(extra))
    after = parse(result)
    require(before['uuid'] == after['uuid'] and before['sections'] == after['sections'],
            'load-edge edit changed original code or data')
    require(after['dependencies'] == before['dependencies'] +
            [{'cmd': '0xc', 'name': n} for n in names], 'unexpected dependency change')
    return bytes(result)


def embedded_info(data):
    off = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        cmd, length = struct.unpack_from('<II', data, off)
        if cmd == 0x19:
            for i in range(struct.unpack_from('<I', data, off + 64)[0]):
                pos = off + 72 + i * 80
                if data[pos:pos + 16].rstrip(b'\0') == b'__info_plist':
                    size, fo = struct.unpack_from('<QI', data, pos + 40)
                    return plistlib.loads(data[fo:fo + size].rstrip(b'\0'))
        off += length
    raise ValueError('original appleaccountd has no embedded Info.plist')


def sign(path, identifier, rights=None):
    original = path.read_bytes()
    before = parse(original)
    # Sign the executable as a file, outside an incomplete bundle staging tree.
    # Bundle resources are installed separately and are never deeply re-signed.
    with tempfile.TemporaryDirectory(prefix='macpad-account-sign-') as folder:
        candidate = Path(folder) / path.name
        candidate.write_bytes(original)
        args = ['codesign', '--force', '--sign', '-', '--identifier', identifier, '--timestamp=none']
        if rights is not None:
            policy = Path(folder) / 'rights.plist'
            policy.write_bytes(plistlib.dumps(rights))
            args += ['--entitlements', policy]
        run(*args, candidate)
        run('codesign', '--verify', '--strict', candidate)
        signed = candidate.read_bytes()
        after = parse(signed)
        for key in ('cpu', 'subtype', 'uuid', 'sections', 'dependencies'):
            require(before[key] == after[key], 'signing changed ' + key)
        if rights is not None:
            actual = run('codesign', '-d', '--entitlements', ':-', candidate)
            require(plistlib.loads(actual) == rights, 'signed entitlement mismatch')
        path.write_bytes(signed)


def build(root, output):
    version = plistlib.loads((root / 'System/Library/CoreServices/SystemVersion.plist').read_bytes())
    require(version['ProductVersion'] == '15.6.1' and version['ProductBuildVersion'] == '24G90',
            'this adapter requires macOS 15.6.1 / 24G90')
    output.mkdir(parents=True, exist_ok=False)
    guest = output / 'guest'
    native = output / 'native'
    native.mkdir()
    files, pinned, provenance = {}, {}, {}

    def target(logical):
        p = guest / logical.lstrip('/')
        p.parent.mkdir(parents=True, exist_ok=True)
        return p

    def record(path, device):
        files[device] = {'file': str(path.relative_to(output)), 'sha256': digest(path.read_bytes())}

    for source, logical in MODULES:
        p = target(logical)
        run('xcrun', '--sdk', 'macosx', 'clang', '-O2', '-fblocks', '-arch', 'arm64e',
            '-mmacosx-version-min=13.0', '-dynamiclib', '-undefined', 'dynamic_lookup',
            '-Wl,-headerpad,0x400', '-Wl,-not_for_dyld_shared_cache', '-I', B, '-framework', 'Foundation', '-framework', 'Security',
            '-install_name', logical, B / source, '-o', p)
        if p.name == 'ns':
            p.write_bytes(append(p.read_bytes(), [LIB + 'libmachook.dylib']))
        sign(p, 'com.macpad.account15.' + p.name)
        record(p, '/var/mnt/rootfs' + logical)
        pinned[logical] = digest(p.read_bytes())

    rights = json.loads((B / 'service-entitlements.json').read_text())
    inputs = json.loads((B / 'inputs.json').read_text())
    services = json.loads((B / 'services.json').read_text())
    for row in services:
        role, _, logical, _, _, _ = row
        spec = inputs['coreauth' if role == 'coreauth-agent' else role]
        data = (root / spec['source'].lstrip('/')).read_bytes()
        require(digest(data) == spec['sha256'], 'original executable changed: ' + role)
        original = arm64e(data)
        # The existing qualified launcher injects libmachook and each job's
        # explicit EXTRA libraries. Only bundled-XPC copies need a direct edge
        # to their local namespace module; this also fits their header padding.
        dependencies = ['@loader_path/ns'] if role in ('accountsd', 'icloudhelper') else []
        p = target(logical)
        p.write_bytes(append(original, dependencies))
        sign(p, ('com.apple.iCloudHelper' if role == 'icloudhelper' else 'com.apple.' + Path(logical).name), rights[role])
        row.append(digest(p.read_bytes()))
        record(p, '/var/mnt/rootfs' + logical)
        provenance[role] = {'input_sha256': digest(data), 'uuid': parse(original)['uuid'],
                            'original_sections_preserved': parse(original)['sections'] == parse(p.read_bytes())['sections']}
        if role == 'appleaccountd':
            info = target(str(Path(logical).parent.parent / 'Info.plist'))
            info.write_bytes(plistlib.dumps(embedded_info(original)))
            record(info, '/var/mnt/rootfs/' + str(info.relative_to(guest)))
        if role == 'icloudhelper':
            info_logical = str(Path(logical).parent.parent / 'Info.plist')
            original_info = str(Path(spec['source']).parent.parent / 'Info.plist')
            info = target(info_logical)
            shutil.copyfile(root / original_info.lstrip('/'), info)
            record(info, '/var/mnt/rootfs' + info_logical)

    helper = target('/usr/local/libexec/macpad-account15/PrivateAccountKeychainHelper')
    run('xcrun', '--sdk', 'macosx', 'clang', '-O2', '-fblocks', '-arch', 'arm64e',
        '-mmacosx-version-min=13.0', '-Wl,-headerpad,0x400', '-framework', 'Foundation', '-framework', 'Security',
        B / 'PrivateAccountKeychainHelper.m', '-o', helper)
    helper.write_bytes(append(helper.read_bytes(), [LIB + 'libmachook.dylib', LIB + 'PrivateAppleAccount15.dylib']))
    sign(helper, 'com.macpad.account15.keychainunlock', plistlib.loads((B / 'keychain.entitlements.plist').read_bytes()))
    pinned['/usr/local/libexec/macpad-account15/PrivateAccountKeychainHelper'] = digest(helper.read_bytes())
    record(helper, '/var/mnt/rootfs/usr/local/libexec/macpad-account15/PrivateAccountKeychainHelper')

    carrier = native / 'AppleIDProxy'
    run('xcrun', '--sdk', 'iphoneos', 'clang', '-O2', '-arch', 'arm64e',
        '-miphoneos-version-min=16.0', '-I', B, B / 'AppleIDProxy-readonly18.c', '-o', carrier)
    sign(carrier, 'com.macwsguide.settings-extension-carrier.com.apple.systempreferences.AppleIDSettings',
         plistlib.loads((B / 'carrier.entitlements.plist').read_bytes()))
    for device in [NATIVE + '/AppleIDProxy', '/var/jb/usr/macOS/libexec/settings-carriers-native15/com.apple.systempreferences.AppleIDSettings',
                   '/var/jb/Applications/MacWSSettingsExtension-com.apple.systempreferences.AppleIDSettings.app/SettingsExtensionProxy']:
        record(carrier, device)

    pane = PANE + '/Contents/MacOS/AppleIDSettings'
    p = target(pane)
    original = arm64e((root / pane.lstrip('/')).read_bytes())
    p.write_bytes(append(original, ['@executable_path/../Frameworks/PrivateAccount15-frontdoor-v32.dylib']))
    sign(p, 'com.apple.systempreferences.AppleIDSettings', plistlib.loads((B / 'pane.entitlements.plist').read_bytes()))
    pinned[pane] = digest(p.read_bytes())
    record(p, '/var/mnt/rootfs' + pane)

    owner = '/System/Library/Accounts/ServiceOwners/AACloudServiceOwner.bundle'
    destination = PANE + '/Contents/Frameworks/AACloudServiceOwner.bundle'
    shutil.copytree(root / owner.lstrip('/'), target(destination), symlinks=True, dirs_exist_ok=True)
    for p in target(destination).rglob('*'):
        require(not p.is_symlink(), 'unexpected service-owner symlink')
        if p.is_file():
            logical = '/' + str(p.relative_to(guest))
            record(p, '/var/mnt/rootfs' + logical)
    pinned[destination + '/Contents/MacOS/AACloudServiceOwner'] = digest(target(destination + '/Contents/MacOS/AACloudServiceOwner').read_bytes())
    for logical, expected in json.loads((B / 'plugins.json').read_text()).items():
        require(digest((root / logical.lstrip('/')).read_bytes()) == expected, 'plugin identity changed: ' + logical)
        pinned[logical] = expected

    for name, destination in [('manager.py', '/var/jb/usr/macOS/bin/macws_private_account15.py'),
                              ('install.py', NATIVE + '/install.py')]:
        p = native / name
        shutil.copyfile(B / name, p)
        record(p, destination)
    jobs = json.loads((B / 'jobs.json').read_text())
    for name, job in jobs.items():
        p = target('/var/db/macws/appleid-signin/templates/' + name)
        p.write_bytes(plistlib.dumps(job))
        record(p, '/var/mnt/rootfs/var/db/macws/appleid-signin/templates/' + name)
    manifest = {'schema': 1, 'version': '15.6.1', 'build': '24G90', 'services': services,
                'modules': pinned, 'files': files, 'provenance': provenance}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Built and verified Apple Account sign-in payload:', output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rootfs', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    build(args.rootfs.resolve(), args.output.resolve())
