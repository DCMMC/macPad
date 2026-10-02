"""Read-only startup protocol contracts; device geometry is tested separately."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "layout/usr/macOS/bin/macos_gui.sh").read_text()
POSTINST = (ROOT / "layout/DEBIAN/postinst").read_text()
HOST = (ROOT / "MacWSHost/main.m").read_text()
TWEAK = (ROOT / "MacWSWindowing/Tweak.x").read_text()
PROTOCOL = (ROOT / "include/macws_windowing_protocol.h").read_text()


class WindowingStartupReadiness(unittest.TestCase):
    def ready(self, probe):
        predicate = 'windowing_bridge_ready() {' + SCRIPT.split(
            'windowing_bridge_ready() {', 1)[1].split('\n}', 1)[0] + '\n}'
        return subprocess.run(['bash', '-c',
            'set -eu\nWINDOWING_STATUS_PROBE="$1"\n' + predicate +
            '\nwindowing_bridge_ready', 'readiness-test', probe],
            capture_output=True).returncode == 0

    def test_live_service_response_is_accepted(self):
        self.assertTrue(self.ready('/usr/bin/true'))

    def test_unready_or_missing_service_rejected(self):
        self.assertFalse(self.ready('/usr/bin/false'))
        self.assertFalse(self.ready('/nonexistent/macws_control_probe'))

    def test_no_production_marker_dependency(self):
        for source in ((ROOT / 'MacWSHost/main.m').read_text(),
                       (ROOT / 'MacWSWindowing/Tweak.x').read_text()):
            self.assertNotIn('dense-grid.loaded', source)
        # Upgrade cleanup may name an obsolete file; no consumer may use it
        # as the bridge's availability or feature-selection predicate.
        self.assertNotIn('WINDOWING_READY_WITNESS', SCRIPT)
        self.assertNotIn('windowing_witness', POSTINST)
        self.assertIn('"$WINDOWING_STATUS_PROBE" windowing-status', SCRIPT)

    def test_readonly_command_cannot_respring(self):
        command = SCRIPT.split('    windowing-status)', 1)[1].split(';;', 1)[0]
        self.assertIn('windowing_bridge_ready', command)
        self.assertNotIn('ensure_windowing_bridge', command)
        self.assertNotIn('killall', command)

    def test_missing_protocol_does_not_cause_automatic_respring(self):
        ensure = SCRIPT.split('ensure_windowing_bridge() {', 1)[1].split('\n}', 1)[0]
        self.assertNotIn('killall', ensure)
        self.assertNotIn('launchctl load', ensure)
        self.assertNotIn('killall SpringBoard', POSTINST)

    def test_independent_scenes_require_live_chamois_state(self):
        self.assertIn('MacWSWindowingChamoisKnown = 1u << 5', PROTOCOL)
        self.assertIn('MacWSWindowingChamoisActive = 1u << 6', PROTOCOL)
        self.assertIn(
            'MacWSObserveChamoisWindowingState(isChamoisWindowingUIEnabled);',
            TWEAK)
        request = HOST.split('static void MacWSRequestNewScene(', 1)[1].split(
            '\n// A fullscreen Scene', 1)[0]
        state = HOST.split(
            'MacWSCurrentIndependentWindowingState(uint64_t *rawStateOut)',
            1)[1].split('\nstatic CGFloat MacWSSceneMaximumAxis', 1)[0]
        self.assertIn('version.minorVersion < 1', state)
        self.assertIn('MacWSIndependentWindowingInactive', state)
        self.assertIn('MacWSCurrentIndependentWindowingState', request)
        self.assertIn('openRequestedWindowInCurrentScene', request)
        self.assertIn('setFullscreenWorkspaceEnabled:YES', request)
        self.assertNotIn(
            'if (windowID != 0 &&\n'
            '        independentWindowing != MacWSIndependentWindowingActive)',
            request)
        self.assertIn('scene-activation reused-current', request)
        self.assertLess(
            request.index('openRequestedWindowInCurrentScene'),
            request.index('requestSceneSessionActivation:existingSession'))
        foreground = HOST.split(
            'static void MacWSEnsureRequestedSceneIsForeground(', 1,
        )[1].split('\nstatic void MacWSRequestNewScene(', 1)[0]
        self.assertGreaterEqual(
            foreground.count('MacWSIndependentWindowingActive'), 2,
        )
        self.assertIn('independent-windowing-became-inactive', foreground)
        self.assertLess(
            foreground.index('MacWSIndependentWindowingActive'),
            foreground.index('requestSceneSessionActivation:windowScene.session'),
        )

    def test_chamois_inactive_sessions_collapse_without_closing_mac_windows(self):
        collapse = HOST.split(
            'static void MacWSScheduleSingleSceneWindowingEnforcement(', 2)[2]
        collapse = collapse.split('\nstatic NSString *MacWSSceneWindowIdentity', 1)[0]
        self.assertIn('MacWSIndependentWindowingInactive', collapse)
        self.assertIn('MacWSSceneSessionsPreservingMacWindow addObject', collapse)
        self.assertIn('requestSceneSessionDestruction:session', collapse)
        self.assertNotIn('MacWSCloseMacWindowForSceneSession', collapse)


if __name__ == '__main__':
    unittest.main()
