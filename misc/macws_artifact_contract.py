"""Build-time checks for a coherent Host/Windowing/runtime package.

These manifests describe build artifacts, never runtime feature switches.
An old cross-linked tweak with a valid checksum is still unsafe to combine
with a new Host. Bind that binary to the source and shared headers it uses.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tarfile


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = 1
QUOTED_INCLUDE = re.compile(r'^\s*#\s*(?:include|import)\s*"([^"]+)"', re.M)
PACKAGE_PATHS = (
    'var/jb/Applications/MacWSHost.app/MacWSHost',
    'var/jb/Applications/MacWSCatalystLauncher.app/MacWSCatalystLauncher',
    'var/jb/Library/MobileSubstrate/DynamicLibraries/MacWSWindowing.dylib',
    'var/jb/Library/MobileSubstrate/DynamicLibraries/MacWSCatalystLaunch.dylib',
    'var/jb/usr/macOS/bin/macwshostd',
    'var/jb/usr/macOS/bin/macws_control_probe',
    'var/jb/usr/macOS/bin/macwsaudiooutd',
    'var/jb/usr/macOS/bin/macos_gui.sh',
    'var/jb/usr/macOS/bin/macws_dense_grid.sh',
    'var/jb/usr/macOS/bin/postinst.sh',
    'var/jb/usr/macOS/bin/macws_diagnostic_flags.sh',
    'var/jb/usr/macOS/bin/macws_retire_legacy_boot_jobs.py',
    'var/jb/usr/macOS/bin/macws_metal_cache_migration.py',
    'var/jb/usr/macOS/bin/macws_refresh_managed_job.py',
    'var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh',
    'var/jb/usr/macOS/gui-launchd/com.macwsguide.coreaudiod.plist',
    'var/jb/usr/macOS/gui-launchd/com.macwsguide.audiocomponentregistrar.plist',
    'var/jb/usr/macOS/gui-launchd/com.macwsguide.audio-output.plist',
    'var/jb/usr/macOS/lib/libmachook.dylib',
    'var/jb/usr/macOS/lib/libmachook_arm64.dylib',
    'var/jb/Library/MobileSubstrate/DynamicLibraries/MTLCompilerBypassOSCheck.dylib',
    'var/jb/usr/macOS/gui-launchd/com.macwsguide.vscode.plist',
    'var/jb/usr/macOS/gui-launchd/com.macwsguide.geekbench.plist',
)
WINDOWING_PATH = PACKAGE_PATHS[2]
CATALYST_PATH = PACKAGE_PATHS[3]
SOURCE_PAYLOADS = {
    'var/jb/usr/macOS/bin/macos_gui.sh': 'layout/usr/macOS/bin/macos_gui.sh',
    'var/jb/usr/macOS/bin/macws_dense_grid.sh': 'layout/usr/macOS/bin/macws_dense_grid.sh',
    'var/jb/usr/macOS/bin/postinst.sh': 'layout/usr/macOS/bin/postinst.sh',
    'var/jb/usr/macOS/bin/macws_diagnostic_flags.sh':
        'layout/usr/macOS/bin/macws_diagnostic_flags.sh',
    'var/jb/usr/macOS/bin/macws_retire_legacy_boot_jobs.py':
        'layout/usr/macOS/bin/macws_retire_legacy_boot_jobs.py',
    'var/jb/usr/macOS/bin/macws_metal_cache_migration.py':
        'layout/usr/macOS/bin/macws_metal_cache_migration.py',
    'var/jb/usr/macOS/bin/macws_refresh_managed_job.py':
        'layout/usr/macOS/bin/macws_refresh_managed_job.py',
    'var/jb/usr/macOS/bin/ensure_settings_extensions_runtime.sh':
        'layout/usr/macOS/bin/ensure_settings_extensions_runtime.sh',
    'var/jb/usr/macOS/bin/ensure_metal2metal_compat.sh':
        'layout/usr/macOS/bin/ensure_metal2metal_compat.sh',
    'var/jb/usr/macOS/bin/ensure_office_metal2metal.py':
        'misc/ensure_office_metal2metal.py',
    'var/jb/usr/macOS/bin/metal2metal.py': 'misc/metal2metal.py',
    'var/jb/usr/macOS/bin/metal2metal_manifest.py': 'misc/metal2metal_manifest.py',
    'var/jb/usr/macOS/bin/metal2metal_profiles.py': 'misc/metal2metal_profiles.py',
    'var/jb/usr/macOS/bin/repack_metallib_macabi.py': 'misc/repack_metallib_macabi.py',
    'var/jb/usr/macOS/gui-launchd/com.macwsguide.coreaudiod.plist':
        'misc/com.macwsguide.coreaudiod.plist',
    'var/jb/usr/macOS/gui-launchd/com.macwsguide.audiocomponentregistrar.plist':
        'misc/com.macwsguide.audiocomponentregistrar.plist',
    'var/jb/usr/macOS/gui-launchd/com.macwsguide.audio-output.plist':
        'misc/com.macwsguide.audio-output.plist',
    'var/jb/usr/macOS/gui-launchd/com.macwsguide.vscode.plist':
        'misc/com.macwsguide.vscode.plist',
    'DEBIAN/postinst': 'layout/DEBIAN/postinst',
}

# Source-controlled payloads must reach the actual archive, not just staging.
# Maintainer scripts live in the separate control archive checked below.
ARCHIVE_PATHS = tuple(sorted(set(PACKAGE_PATHS) | {
    name for name in SOURCE_PAYLOADS if not name.startswith('DEBIAN/')
}))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def source_hashes(root: Path) -> dict[str, str]:
    root = root.resolve()
    pending = [root / 'Makefile', root / 'config/production.mk']
    pending.extend(path for path in (root / 'MacWSWindowing').rglob('*')
                   if path.is_file() and not any(
                       part.startswith('.') for part in path.relative_to(root).parts))
    sources = {}
    while pending:
        path = pending.pop().resolve()
        relative = path.relative_to(root).as_posix()
        if relative in sources:
            continue
        sources[relative] = sha256(path)
        if path.suffix not in ('.x', '.m', '.mm', '.c', '.h'):
            continue
        for include in QUOTED_INCLUDE.findall(path.read_text()):
            candidates = (path.parent / include, root / 'include' / include,
                          root / include)
            dependency = next((item for item in candidates if item.is_file()), None)
            if dependency is None:
                raise ValueError(f'unresolved local include {include} in {relative}')
            pending.append(dependency)
    return dict(sorted(sources.items()))


def manifest(root: Path, binary: Path, source_snapshot: Path | None = None) -> dict:
    sources = source_hashes(root)
    if source_snapshot is not None:
        snapshot = json.loads(source_snapshot.read_text())
        if snapshot.get('schema') != SCHEMA or snapshot.get('sources') != sources:
            raise ValueError('Windowing source changed during cross-build; rebuild it')
    return {'schema': SCHEMA, 'artifact': 'MacWSWindowing',
            'binary_sha256': sha256(binary), 'sources': sources}


def verify_windowing_rootless_load_commands(binary: Path) -> None:
    """Reject a Windowing image that dyld cannot resolve on rootless iOS.

    Apple ld64 still accepts the rootful Theos defaults, so authenticated
    arm64e fixups and a valid signature alone do not prove that SpringBoard
    can load the image.  Inspect the finished binary rather than inferring its
    dependency paths from the requested package scheme.
    """
    result = subprocess.run(['otool', '-L', str(binary)], text=True,
                            capture_output=True)
    if result.returncode:
        raise ValueError('cannot inspect MacWSWindowing load commands: ' +
                         result.stderr.strip())
    dependencies = [line.strip().split(' (compatibility version', 1)[0]
                    for line in result.stdout.splitlines()[1:] if line.strip()]
    rootful = sorted(path for path in dependencies
                     if path.startswith('/Library/'))
    if rootful:
        raise ValueError('MacWSWindowing contains rootful load commands: ' +
                         ', '.join(rootful))
    substrate = '@rpath/CydiaSubstrate.framework/CydiaSubstrate'
    if substrate not in dependencies:
        raise ValueError('MacWSWindowing lacks rootless Substrate dependency: ' +
                         substrate)


def verify(root: Path, binary: Path, manifest_path: Path) -> None:
    expected = json.loads(manifest_path.read_text())
    actual = manifest(root, binary)
    if expected.get('schema') != SCHEMA or expected.get('artifact') != 'MacWSWindowing':
        raise ValueError('unsupported MacWSWindowing build manifest')
    if expected.get('binary_sha256') != actual['binary_sha256']:
        raise ValueError('MacWSWindowing binary differs from its build manifest')
    old = expected.get('sources', {})
    changed = sorted(path for path in old.keys() | actual['sources'].keys()
                     if old.get(path) != actual['sources'].get(path))
    if changed:
        raise ValueError('stale MacWSWindowing cross-build; rebuild on Mac: '
                         + ', '.join(changed))


def verify_package(package: Path, staging: Path, binary: Path,
                   root: Path | None = None) -> None:
    expected = {name: sha256(staging / name) for name in ARCHIVE_PATHS}
    if root is not None:
        for name, source in SOURCE_PAYLOADS.items():
            # Theos converts XML plists to binary during normal staging.
            # Compare their decoded configuration here; archive-to-staging
            # below still requires every installed byte to match exactly.
            if name.endswith('.plist'):
                same = plistlib.loads((staging / name).read_bytes()) == \
                    plistlib.loads((root / source).read_bytes())
            else:
                same = sha256(staging / name) == sha256(root / source)
            if not same:
                raise ValueError(f'staged runtime differs from current source: {source}')
    if expected[WINDOWING_PATH] != sha256(binary):
        raise ValueError('staged MacWSWindowing differs from validated cross-build')
    found = set()
    # Stream the archive instead of extracting its files or trusting timestamps.
    # This checks the actual bytes dpkg will install after Theos staging/signing.
    with subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(package)],
                          stdout=subprocess.PIPE) as process:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for member in archive:
                name = member.name.removeprefix('./')
                if name == 'var/jb/usr/lib/TweakInject/MacWSWindowing.dylib':
                    raise ValueError('package contains a second unvalidated Windowing tweak')
                if name not in expected:
                    continue
                if name in found or not member.isfile():
                    raise ValueError(f'duplicate or non-file runtime payload: {name}')
                stream = archive.extractfile(member)
                digest = hashlib.sha256()
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    digest.update(block)
                if digest.hexdigest() != expected[name]:
                    raise ValueError(f'package differs from staged runtime: {name}')
                found.add(name)
        if process.wait() != 0:
            raise ValueError('cannot read package payload')
    missing = sorted(expected.keys() - found)
    if missing:
        raise ValueError('package is missing runtime payload: ' + ', '.join(missing))
    with subprocess.Popen(['dpkg-deb', '--ctrl-tarfile', str(package)],
                          stdout=subprocess.PIPE) as process:
        postinst = None
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for member in archive:
                if member.name.removeprefix('./') == 'postinst':
                    if postinst is not None or not member.isfile():
                        raise ValueError('duplicate or non-file package postinst')
                    postinst = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
        if process.wait() != 0:
            raise ValueError('cannot read package maintainer scripts')
    if postinst != sha256(staging / 'DEBIAN/postinst'):
        raise ValueError('package postinst differs from staged installation logic')


def verify_catalyst_abi(binary: Path) -> None:
    # RunningBoard's tweak is built by on-device lld. Keep its refresh observer
    # free of the static CF objects/global blocks whose authenticated-data
    # fixups were the SpringBoard lld failure. The observer constructs its name
    # at runtime and registers a C callback instead. Inspect the actual image,
    # not just the source spelling, before permitting package installation.
    commands = (['otool', '-arch', 'arm64e', '-l', str(binary)],
                ['nm', '-arch', 'arm64e', '-u', str(binary)])
    outputs = []
    for command in commands:
        result = subprocess.run(command, text=True, capture_output=True)
        if result.returncode != 0:
            raise ValueError('cannot verify Catalyst arm64e ABI: ' + result.stderr.strip())
        outputs.append(result.stdout)
    if 'LC_SEGMENT_64' not in outputs[0]:
        raise ValueError('Catalyst package has no readable arm64e Mach-O slice')
    if re.search(r'sectname\s+__cfstring\b', outputs[0]) or \
            '__NSConcreteGlobalBlock' in outputs[1]:
        raise ValueError('Catalyst arm64e requires unvalidated static-object fixups; '
                         'use runtime CF strings/C callbacks or a validated Apple-ld64 build')


def verify_production_policy(root: Path) -> None:
    # A coherent archive can still faithfully ship a diagnostic configuration.
    # Enforce the source inventory at the same mandatory admission boundary,
    # not only when an operator remembers to run the separate audit.
    try:
        result = subprocess.run(
            [sys.executable, str(root / 'misc/audit_runtime_switches.py')],
            text=True, capture_output=True, timeout=30)
    except subprocess.TimeoutExpired as error:
        raise ValueError('production policy audit timed out') from error
    if result.returncode:
        raise ValueError('production policy audit failed: ' +
                         (result.stderr + result.stdout).strip()[:4000])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('snapshot', 'create', 'verify', 'verify-package'))
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--package', type=Path)
    parser.add_argument('--staging', type=Path)
    parser.add_argument('--source-snapshot', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'snapshot':
            args.manifest.write_text(json.dumps(
                {'schema': SCHEMA, 'sources': source_hashes(args.root)},
                indent=2, sort_keys=True) + '\n')
        elif not args.binary:
            parser.error(f'{args.action} requires --binary')
        elif args.action == 'create':
            verify_windowing_rootless_load_commands(args.binary)
            args.manifest.write_text(json.dumps(manifest(args.root, args.binary,
                                                        args.source_snapshot),
                                                indent=2, sort_keys=True) + '\n')
        else:
            verify_windowing_rootless_load_commands(args.binary)
            verify(args.root, args.binary, args.manifest)
            if args.action == 'verify-package':
                if not args.package or not args.staging:
                    parser.error('verify-package requires --package and --staging')
                verify_production_policy(args.root)
                verify_package(args.package, args.staging, args.binary, args.root)
                verify_catalyst_abi(args.staging / CATALYST_PATH)
        print(f'MacWS artifact contract: {args.action} passed')
        return 0
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
