"""Exercise stale cross-build and stale/missing Debian payload rejection."""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import macws_artifact_contract as contract


class ArtifactContract(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name, contents in {
            'Makefile': 'all:\n',
            'config/production.mk': 'OPTFLAG ?= -O2\n',
            'MacWSWindowing/Makefile': 'MacWSWindowing_FILES = Tweak.x\n',
            'MacWSWindowing/Tweak.x': '#include "../include/shared.h"\n',
            'include/shared.h': '#include "capability.h"\n',
            'include/capability.h': '#define ABI 1\n',
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        self.binary = self.root / 'MacWSWindowing.dylib'
        self.binary.write_bytes(b'cross-linked-Apple-ld64-artifact')
        self.manifest = self.root / 'MacWSWindowing.build.json'
        self.manifest.write_text(json.dumps(contract.manifest(self.root, self.binary)))

    def test_exact_source_and_binary_are_accepted(self):
        contract.verify(self.root, self.binary, self.manifest)

    def test_source_migration_rejects_self_consistent_old_binary_and_hash(self):
        (self.root / 'include/capability.h').write_text('#define ABI 2\n')
        with self.assertRaisesRegex(ValueError, 'include/capability.h'):
            contract.verify(self.root, self.binary, self.manifest)

    def test_changed_binary_is_rejected(self):
        self.binary.write_bytes(b'another-build')
        with self.assertRaisesRegex(ValueError, 'binary differs'):
            contract.verify(self.root, self.binary, self.manifest)

    def test_edit_during_build_cannot_label_old_object_with_new_source(self):
        snapshot = self.root / 'before-build.json'
        snapshot.write_text(json.dumps({'schema': contract.SCHEMA,
                                       'sources': contract.source_hashes(self.root)}))
        (self.root / 'include/capability.h').write_text('#define ABI 2\n')
        with self.assertRaisesRegex(ValueError, 'changed during cross-build'):
            contract.manifest(self.root, self.binary, snapshot)

    def test_rootful_windowing_load_command_is_rejected(self):
        output = (f'{self.binary}:\n'
                  '\t@rpath/MacWSWindowing.dylib (compatibility version 0.0.0)\n'
                  '\t/Library/Frameworks/CydiaSubstrate.framework/'
                  'CydiaSubstrate (compatibility version 0.0.0)\n')
        with mock.patch.object(contract.subprocess, 'run',
                return_value=subprocess.CompletedProcess([], 0, output, '')):
            with self.assertRaisesRegex(ValueError, 'rootful load commands'):
                contract.verify_windowing_rootless_load_commands(self.binary)

    def test_rootless_windowing_load_command_is_accepted(self):
        output = (f'{self.binary}:\n'
                  '\t@rpath/MacWSWindowing.dylib (compatibility version 0.0.0)\n'
                  '\t@rpath/CydiaSubstrate.framework/CydiaSubstrate '
                  '(compatibility version 0.0.0)\n')
        with mock.patch.object(contract.subprocess, 'run',
                return_value=subprocess.CompletedProcess([], 0, output, '')):
            contract.verify_windowing_rootless_load_commands(self.binary)

    def test_missing_transitive_header_is_rejected(self):
        (self.root / 'include/capability.h').unlink()
        with self.assertRaisesRegex(ValueError, 'unresolved local include'):
            contract.verify(self.root, self.binary, self.manifest)

    def test_policy_audit_success_required_not_just_matching_archive(self):
        script = self.root / 'misc/audit_runtime_switches.py'
        script.parent.mkdir()
        script.write_text('raise SystemExit(1)\n')
        with self.assertRaisesRegex(ValueError, 'production policy audit failed'):
            contract.verify_production_policy(self.root)
        script.write_text('raise SystemExit(0)\n')
        contract.verify_production_policy(self.root)

    def test_missing_or_timed_out_policy_audit_fails_closed(self):
        with self.assertRaisesRegex(ValueError, 'production policy audit failed'):
            contract.verify_production_policy(self.root)
        with mock.patch.object(contract.subprocess, 'run',
                side_effect=subprocess.TimeoutExpired('audit', 30)):
            with self.assertRaisesRegex(ValueError, 'production policy audit timed out'):
                contract.verify_production_policy(self.root)

    def test_package_command_calls_policy_gate_before_archive_acceptance(self):
        with mock.patch.object(contract.sys, 'argv', [
                'contract', 'verify-package', '--root', str(self.root),
                '--binary', str(self.binary), '--manifest', str(self.manifest),
                '--package', str(self.root / 'candidate.deb'),
                '--staging', str(self.root / 'staging')]), \
                mock.patch.object(contract, 'verify_production_policy',
                    side_effect=ValueError('fixture diagnostic present')) as audit, \
                mock.patch.object(contract,
                    'verify_windowing_rootless_load_commands'), \
                mock.patch.object(contract, 'verify_package') as archive:
            self.assertEqual(contract.main(), 1)
            audit.assert_called_once_with(self.root)
            archive.assert_not_called()

    def package(self, omitted=None):
        staging = self.root / 'staging'
        for name in contract.ARCHIVE_PATHS:
            path = staging / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps({'EnvironmentVariables': {'MACWS_TEST': '1'}},
                                            fmt=plistlib.FMT_BINARY)
                             if name.endswith('.plist') else
                             self.binary.read_bytes() if name == contract.WINDOWING_PATH
                             else name.encode())
        (staging / 'DEBIAN').mkdir()
        (staging / 'DEBIAN/postinst').write_text('true\n')
        (staging / 'DEBIAN/postinst').chmod(0o755)
        payload = self.root / 'payload'
        shutil.copytree(staging, payload)
        if omitted:
            (payload / omitted).unlink()
        (payload / 'DEBIAN/control').write_text(
            'Package: artifact-contract-test\nVersion: 1\nArchitecture: all\n'
            'Maintainer: MacWS test\nDescription: payload contract fixture\n')
        package = self.root / 'test.deb'
        subprocess.run(['dpkg-deb', '--build', str(payload), str(package)],
                       check=True, capture_output=True)
        return package, staging

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_actual_debian_payload_matches_staging(self):
        package, staging = self.package()
        contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_new_staging_does_not_validate_old_archive(self):
        package, staging = self.package()
        (staging / contract.PACKAGE_PATHS[0]).write_bytes(b'new-host')
        with self.assertRaisesRegex(ValueError, 'package differs from staged runtime'):
            contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_compiler_target_fix_must_reach_actual_archive(self):
        package, staging = self.package()
        name = ('var/jb/Library/MobileSubstrate/DynamicLibraries/'
                'MTLCompilerBypassOSCheck.dylib')
        self.assertIn(name, contract.PACKAGE_PATHS)
        (staging / name).write_bytes(b'new-compiler-target-adapter')
        with self.assertRaisesRegex(ValueError, 'package differs from staged runtime'):
            contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_missing_audio_job_stops_installation(self):
        name = 'var/jb/usr/macOS/gui-launchd/com.macwsguide.audio-output.plist'
        package, staging = self.package(omitted=name)
        with self.assertRaisesRegex(ValueError, 'missing runtime payload'):
            contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_missing_safe_lifecycle_helper_stops_installation(self):
        name = 'var/jb/usr/macOS/bin/macws_refresh_managed_job.py'
        package, staging = self.package(omitted=name)
        with self.assertRaisesRegex(ValueError, 'missing runtime payload'):
            contract.verify_package(package, staging, self.binary)

    def test_all_source_payloads_are_covered_by_archive_verification(self):
        self.assertTrue(set(contract.SOURCE_PAYLOADS) - {'DEBIAN/postinst'} <=
                        set(contract.ARCHIVE_PATHS))

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_missing_office_shader_provisioner_stops_installation(self):
        name = 'var/jb/usr/macOS/bin/ensure_office_metal2metal.py'
        package, staging = self.package(omitted=name)
        with self.assertRaisesRegex(ValueError, 'missing runtime payload'):
            contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_changed_office_shader_provisioner_must_reach_actual_archive(self):
        name = 'var/jb/usr/macOS/bin/ensure_office_metal2metal.py'
        package, staging = self.package()
        (staging / name).write_bytes(b'new-office-shader-provisioner')
        with self.assertRaisesRegex(ValueError, 'package differs from staged runtime'):
            contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_old_staged_startup_script_is_rejected(self):
        package, staging = self.package()
        for name, source in contract.SOURCE_PAYLOADS.items():
            path = self.root / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((staging / name).read_bytes())
        (self.root / 'layout/usr/macOS/bin/postinst.sh').write_text('new-audio-trust\n')
        with self.assertRaisesRegex(ValueError, 'staged runtime differs from current source'):
            contract.verify_package(package, staging, self.binary, self.root)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_old_archived_installation_logic_is_rejected(self):
        package, staging = self.package()
        (staging / 'DEBIAN/postinst').write_text('new-installation-logic\n')
        with self.assertRaisesRegex(ValueError, 'package postinst differs'):
            contract.verify_package(package, staging, self.binary)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_xml_source_and_binary_staged_plist_are_equivalent(self):
        package, staging = self.package()
        for name, source in contract.SOURCE_PAYLOADS.items():
            path = self.root / source
            path.parent.mkdir(parents=True, exist_ok=True)
            data = (staging / name).read_bytes()
            path.write_bytes(plistlib.dumps(plistlib.loads(data), fmt=plistlib.FMT_XML)
                             if name.endswith('.plist') else data)
        contract.verify_package(package, staging, self.binary, self.root)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_changed_plist_environment_is_rejected(self):
        package, staging = self.package()
        for name, source in contract.SOURCE_PAYLOADS.items():
            path = self.root / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((staging / name).read_bytes())
        job = self.root / 'misc/com.macwsguide.coreaudiod.plist'
        value = plistlib.loads(job.read_bytes())
        value['EnvironmentVariables']['MACWS_TEST'] = '0'
        job.write_bytes(plistlib.dumps(value))
        with self.assertRaisesRegex(ValueError, 'staged runtime differs from current source'):
            contract.verify_package(package, staging, self.binary, self.root)

    @unittest.skipUnless(shutil.which('dpkg-deb'), 'dpkg-deb required')
    def test_retired_browser_debug_argv_cannot_survive_in_staging(self):
        package, staging = self.package()
        for name, source in contract.SOURCE_PAYLOADS.items():
            path = self.root / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((staging / name).read_bytes())
        job = self.root / 'misc/com.macwsguide.vscode.plist'
        value = plistlib.loads(job.read_bytes())
        value['ProgramArguments'] = ['Electron', '--use-angle=metal']
        job.write_bytes(plistlib.dumps(value))
        with self.assertRaisesRegex(ValueError, 'staged runtime differs from current source'):
            contract.verify_package(package, staging, self.binary, self.root)


if __name__ == '__main__':
    unittest.main()
