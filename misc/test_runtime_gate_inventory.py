"""Production defaults, diagnostic inventory and transport-config regressions."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import audit_runtime_switches as audit

ROOT = audit.ROOT


class RuntimeGateInventory(unittest.TestCase):
    def test_discovers_multiline_macro_variable_and_objc_consumers(self):
        source = r'''
// getenv("MACWS_COMMENT_ONLY")
const char *flag = "/tmp/macws_variable_gate";
const char *split = getenv(
    "MACWS_SPLIT_" "ENV");
if (access(flag, F_OK) == 0) run();
MACWS_DEFINE_STARTUP_FLAG(test_gate, "/tmp/macws_macro_gate")
if ([files fileExistsAtPath:@"/tmp/com.macwsguide.test"]) run();
environment[@"MACWS_CHILD_CONTRACT"] = @"1";
'''
        env, flags = audit.discovered_switches({Path('test.m'): source})
        self.assertEqual(env, {'MACWS_SPLIT_ENV', 'MACWS_CHILD_CONTRACT'})
        self.assertEqual(flags, {'/tmp/macws_variable_gate',
                                '/tmp/macws_macro_gate',
                                '/tmp/com.macwsguide.test'})

    def test_shell_config_and_presence_gate_are_included(self):
        source = '''
GATE="$ROOTFS/private/tmp/macws_test_gate"
if [ -e "$GATE" ]; then work; fi
device="${MACWS_TEST_DEVICE:-localhost}"
echo "$MACWS_LOCAL_OUTPUT"
'''
        env, flags = audit.discovered_switches({Path('test.sh'): source})
        self.assertEqual(env, {'MACWS_TEST_DEVICE'})
        self.assertEqual(flags, {'/private/tmp/macws_test_gate'})

    def test_all_file_flags_are_debug_or_obsolete_and_cleanup_is_complete(self):
        manifest = audit.load_manifest()
        for (kind, name), (production, _, _) in manifest.items():
            if kind == 'flag':
                self.assertIn(production, {'off', 'transient'}, name)
        expected = audit.diagnostic_cleanup_script(manifest)
        self.assertEqual(audit.CLEANUP_HELPER.read_text(), expected)
        result = subprocess.run(['bash', '-c',
                                 'source "$1"; macws_diagnostic_flag_paths',
                                 'cleanup-test', str(audit.CLEANUP_HELPER)],
                                check=True, capture_output=True, text=True)
        self.assertEqual(set(result.stdout.splitlines()),
                         {name for kind, name in manifest if kind == 'flag'})
        self.assertNotIn('/tmp/macws_audio_ring', result.stdout)
        self.assertNotIn('/tmp/macws_capture_done', result.stdout)
        self.assertNotIn('/tmp/macws_final_composite.state', result.stdout)

    def test_cleanup_generator_rejects_broad_or_persistent_targets(self):
        for path in ('/tmp/*', '/var/mobile/macws_debug', '/tmp/../var', '/tmp/'):
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    audit.diagnostic_cleanup_script({('flag', path):
                        ('off', 'diagnostic', 'test')})

    def test_obsolete_production_files_have_no_consumers(self):
        files = {ROOT / path: (ROOT / path).read_text() for path in
                 ('libmachook/mac_hooks.m', 'libmachook/Metal_hooks.x',
                  'macwshostd/main.m')}
        _, flags = audit.discovered_switches(files)
        for name in ('macws_kcmd_fix', 'macws_kcmd_wrapped_fix',
                     'macws_cancel_completion', 'macws_owned_scanout',
                     'macws_final_composite', 'macws_vnc_share', 'ws_headless'):
            self.assertNotIn('/tmp/' + name, flags)
        self.assertNotIn('getenv("MACWS_AGX_NATIVE")',
                         files[ROOT / 'libmachook/Metal_hooks.x'])

    def test_audio_is_not_an_environment_opt_in(self):
        bridge = (ROOT / 'libmachook/AudioRenderBridge.m').read_text()
        self.assertNotIn('getenv("MACWS_AUDIO_RENDER_BRIDGE")', bridge)
        with (ROOT / 'misc/com.macwsguide.vscode.plist').open('rb') as stream:
            job = plistlib.load(stream)
        self.assertNotIn('MACWS_AUDIO_RENDER_BRIDGE',
                         job.get('EnvironmentVariables', {}))

    def test_audio_shared_cache_hooks_use_dyld_interposition(self):
        bridge = (ROOT / 'libmachook/AudioRenderBridge.m').read_text()
        self.assertNotIn('#import <substrate.h>', bridge)
        self.assertNotIn('MSHookFunction(', bridge)
        self.assertIn('dlsym(RTLD_NEXT, "AudioUnitSetProperty")', bridge)
        for entry in (
                'AudioUnitSetProperty', 'AudioOutputUnitStart',
                'AudioOutputUnitStop', 'AudioComponentInstanceDispose'):
            self.assertIn(f'DYLD_INTERPOSE(MacWS{entry}', bridge)

    def test_m2_software_audio_cadence_excludes_callback_work(self):
        bridge = (ROOT / 'libmachook/AudioRenderBridge.m').read_text()
        self.assertIn('strcmp(machine, "iPad14,5") == 0;', bridge)
        self.assertIn('nextDeadline += quantumTicks;', bridge)
        self.assertIn('remainingTicks = nextDeadline - now;', bridge)
        self.assertIn('now - nextDeadline > quantumTicks * 8', bridge)
        self.assertNotIn('(void)nanosleep(&quantum, NULL);', bridge)

    def test_native_video_production_policies_do_not_require_opt_in(self):
        hooks = (ROOT / 'libmachook/mac_hooks.m').read_text()
        metal = (ROOT / 'libmachook/Metal_hooks.x').read_text()
        compact_hooks = ''.join(hooks.split())
        self.assertTrue('MacWSProductionDefaultEnabled(getenv("MACWS_CHROMIUM_COMPOSITE_OVERLAYS"))' in compact_hooks)
        self.assertEqual(metal.count('MacWSProductionDefaultEnabled(getenv("MACWS_SDR_SCANOUT"))'), 2)
        self.assertTrue('MacWSDiagnosticSwitchEnabled(getenv("MACWS_PIN_FALLBACK"))' in compact_hooks)
        for path in list((ROOT / 'layout').rglob('*.plist')) + list((ROOT / 'misc').glob('com.macwsguide.*.plist')):
            with path.open('rb') as stream:
                job = plistlib.load(stream)
            self.assertNotIn('MACWS_PIN_FALLBACK', job.get('EnvironmentVariables', {}), str(path))

    @unittest.skipUnless(shutil.which('clang'), 'C compiler required')
    def test_compiled_clean_environment_production_default(self):
        fixture = r'''
#include "macws_production_policy.h"
#include <assert.h>
#include <stdlib.h>
int main(void) {
    unsetenv("MACWS_POLICY_TEST");
    assert(MacWSProductionDefaultEnabled(getenv("MACWS_POLICY_TEST")));
    setenv("MACWS_POLICY_TEST", "1", 1);
    assert(MacWSProductionDefaultEnabled(getenv("MACWS_POLICY_TEST")));
    setenv("MACWS_POLICY_TEST", "0", 1);
    assert(!MacWSProductionDefaultEnabled(getenv("MACWS_POLICY_TEST")));
    unsetenv("MACWS_POLICY_TEST");
    assert(MacWSProductionDefaultEnabled(getenv("MACWS_POLICY_TEST")));
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'production-policy-test'
            subprocess.run(['clang', '-x', 'c', '-', '-O2', '-I',
                            str(ROOT / 'include'), '-o', str(binary)],
                           input=fixture, text=True, capture_output=True,
                           check=True)
            subprocess.run([str(binary)], check=True)

    def test_vnc_choice_updates_job_environment_without_flag_files(self):
        script = (ROOT / 'layout/usr/macOS/bin/macos_gui.sh').read_text()
        body = script.split('"$WINDOWSERVER_PLIST" "$WANT_VNC" <<\'PY\'', 1)[1]
        body = body.split('\n', 1)[1].split('\nPY\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'windowserver.plist'
            path.write_bytes(plistlib.dumps({'Label': 'WindowServer',
                'EnvironmentVariables': {'CA_VSYNC_OFF': '1'}}))
            for choice in ('0', '1', '0'):
                subprocess.run([sys.executable, '-', str(path), choice],
                               input=body, text=True, capture_output=True,
                               check=True)
                job = plistlib.loads(path.read_bytes())
                self.assertEqual(job['EnvironmentVariables']['MACWS_VNC_SHARE'], choice)
                self.assertEqual(job['EnvironmentVariables']['CA_VSYNC_OFF'], '1')
                self.assertEqual(list(Path(directory).iterdir()), [path])

    @staticmethod
    def migrate_jobs(paths):
        script = (ROOT / 'layout/usr/macOS/bin/macos_gui.sh').read_text()
        body = script.split("<<'MACWS_JOB_MIGRATION'\n", 1)[1]
        body = body.split('\nMACWS_JOB_MIGRATION\n', 1)[0]
        return subprocess.run([sys.executable, '-',
            '/var/jb/usr/macOS/bin/launchdchrootexec', '/var/mnt/rootfs',
            *map(str, paths)], input=body, text=True, capture_output=True)

    def test_optional_legacy_job_migrates_without_changing_functional_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'com.macwsguide.chrome150.plist'
            job = plistlib.loads((ROOT / 'misc' / path.name).read_bytes())
            job['EnvironmentVariables']['MACWS_PIN_FALLBACK'] = '1'
            job['EnvironmentVariables']['NO_COLOR'] = '1'
            path.write_bytes(plistlib.dumps(job))
            path.chmod(0o640)
            expected = plistlib.loads(path.read_bytes())
            del expected['EnvironmentVariables']['MACWS_PIN_FALLBACK']
            result = self.migrate_jobs([path, Path(directory) / 'missing.plist'])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(plistlib.loads(path.read_bytes()), expected)
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual(list(Path(directory).iterdir()), [path])
            self.assertFalse(audit.production_environment_errors(audit.load_manifest(), [path]))
            migrated_bytes = path.read_bytes()
            result = self.migrate_jobs([path])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')
            self.assertEqual(path.read_bytes(), migrated_bytes)

    def test_legacy_job_migration_retains_real_diagnostic_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'com.macwsguide.chrome150.plist'
            job = plistlib.loads((ROOT / 'misc' / path.name).read_bytes())
            job['EnvironmentVariables'].update(MACWS_PIN_FALLBACK='1', MallocScribble='1')
            path.write_bytes(plistlib.dumps(job))
            result = self.migrate_jobs([path])
            self.assertEqual(result.returncode, 0, result.stderr)
            errors = audit.production_environment_errors(audit.load_manifest(), [path])
            self.assertEqual(len(errors), 1)
            self.assertIn('MallocScribble', errors[0])

    def test_legacy_job_migration_fails_closed_before_modifying_any_job(self):
        with tempfile.TemporaryDirectory() as directory:
            valid = Path(directory) / 'com.macwsguide.chrome150.plist'
            invalid = Path(directory) / 'com.macwsguide.steam.runtime.plist'
            job = plistlib.loads((ROOT / 'misc' / valid.name).read_bytes())
            job['EnvironmentVariables']['MACWS_PIN_FALLBACK'] = '1'
            valid.write_bytes(plistlib.dumps(job))
            unchanged = valid.read_bytes()
            bad_jobs = [b'not a plist', plistlib.dumps({'Label': 'com.apple.WindowServer'}),
                        plistlib.dumps(dict(job, EnvironmentVariables=['not', 'a', 'dictionary']))]
            for content in bad_jobs:
                invalid.write_bytes(content)
                result = self.migrate_jobs([valid, invalid])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(valid.read_bytes(), unchanged)
                self.assertEqual(invalid.read_bytes(), content)

    def test_actual_managed_plists_are_accepted_by_migration(self):
        with tempfile.TemporaryDirectory() as directory:
            sources = [ROOT / 'layout/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist']
            sources += [ROOT / 'misc' / name for name in
                        ('com.macwsguide.vscode.plist', 'com.macwsguide.chrome150.plist',
                         'com.macwsguide.steam.runtime.plist')]
            paths = []
            for source in sources:
                path = Path(directory) / source.name
                path.write_bytes(source.read_bytes())
                paths.append(path)
            result = self.migrate_jobs(paths)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_user_preferences_and_scoped_production_contracts_are_not_debug(self):
        manifest = audit.load_manifest()
        result = subprocess.run(['bash', '-c',
            'source "$1"; macws_diagnostic_environment_pattern', 'cleanup-test',
            str(audit.CLEANUP_HELPER)], check=True, capture_output=True, text=True)
        forbidden = result.stdout.strip().split('|')
        for name in ('NO_COLOR', 'MACWS_CATALOG_REGISTRATION', 'MACWS_STRAY_AGX_COMPAT'):
            self.assertEqual(manifest['env', name][0], 'auto')
            self.assertNotIn(name, forbidden)

    @staticmethod
    def retire_legacy_vscode(legacy, active, quarantine):
        script = (ROOT / 'layout/usr/macOS/bin/macos_gui.sh').read_text()
        body = script.split("<<'MACWS_LEGACY_JOB_RETIREMENT'\n", 1)[1]
        body = body.split('\nMACWS_LEGACY_JOB_RETIREMENT\n', 1)[0]
        return subprocess.run([sys.executable, '-', str(legacy), str(active),
            str(quarantine), '/var/jb/usr/macOS/bin/launchdchrootexec',
            '/var/mnt/rootfs'], input=body, text=True, capture_output=True)

    def test_legacy_vscode_quarantine_preserves_bad_comment_original_and_active_job(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            legacy = base / 'com.macwsguide.vscode.plist'
            active = base / 'active.plist'
            quarantine = base / 'retired-launch-jobs'
            active.write_bytes((ROOT / 'misc/com.macwsguide.vscode.plist').read_bytes())
            active_bytes = active.read_bytes()
            original = active_bytes.replace(b'<dict>',
                b'<!-- old --no-concurrent-* comment -->\n<dict>', 1)
            legacy.write_bytes(original)
            legacy.chmod(0o640)
            result = self.retire_legacy_vscode(legacy, active, quarantine)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(legacy.exists())
            self.assertEqual(active.read_bytes(), active_bytes)
            retired, = quarantine.iterdir()
            self.assertTrue(retired.name.endswith('.plist.disabled'))
            self.assertEqual(retired.read_bytes(), original)
            self.assertEqual(retired.stat().st_mode & 0o777, 0o640)
            # Missing legacy file and a reintroduced identical copy are both
            # idempotent without touching the active job or losing evidence.
            self.assertEqual(self.retire_legacy_vscode(legacy, active, quarantine).returncode, 0)
            legacy.write_bytes(original)
            self.assertEqual(self.retire_legacy_vscode(legacy, active, quarantine).returncode, 0)
            self.assertEqual(list(quarantine.iterdir()), [retired])
            self.assertEqual(retired.read_bytes(), original)
            self.assertEqual(active.read_bytes(), active_bytes)

    def test_legacy_vscode_unknown_malformed_oversized_or_active_identity_is_kept(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            legacy = base / 'com.macwsguide.vscode.plist'
            active = base / 'active.plist'
            quarantine = base / 'retired-launch-jobs'
            job = plistlib.loads((ROOT / 'misc/com.macwsguide.vscode.plist').read_bytes())
            bad_jobs = [b'not a plist', b'x' * 65537,
                plistlib.dumps(dict(job, Label='com.apple.finder')),
                plistlib.dumps(dict(job, ProgramArguments=['/bin/sh', '-c', 'anything']))]
            for original in bad_jobs:
                legacy.write_bytes(original)
                result = self.retire_legacy_vscode(legacy, active, quarantine)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(legacy.read_bytes(), original)
                self.assertFalse(quarantine.exists())
            legacy.write_bytes(plistlib.dumps(job))
            result = self.retire_legacy_vscode(legacy, legacy, quarantine)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(legacy.exists())
            self.assertFalse(quarantine.exists())


if __name__ == '__main__':
    unittest.main()
