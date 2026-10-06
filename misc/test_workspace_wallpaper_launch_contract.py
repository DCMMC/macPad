"""Guard the bounded, headless workspace-wallpaper helper launch."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "layout/usr/macOS/bin/macos_gui.sh").read_text()


class WorkspaceWallpaperLaunchContract(unittest.TestCase):
    def test_late_navigation_helper_uses_headless_constructor_scope(self):
        body = SCRIPT[SCRIPT.index("ensure_navigation_spaces()"):
                      SCRIPT.index("\nrefresh_dock_after_navigation_spaces()")]
        self.assertIn(
            "MACWS_UTILITY_PROCESS=1 /var/jb/usr/bin/timeout -k 2 20",
            body)
        self.assertIn("ensure-navigation-spaces", body)

    def test_wallpaper_helper_uses_the_existing_headless_constructor_scope(self):
        body = SCRIPT[SCRIPT.index("apply_workspace_wallpaper()"):
                      SCRIPT.index("\ndesktop_job_loaded()")]
        self.assertIn(
            "MACWS_UTILITY_PROCESS=1 /var/jb/usr/bin/timeout -k 2 20",
            body)
        self.assertIn('set-wallpaper "$WORKSPACE_WALLPAPER"', body)
        self.assertIn('rc=$?', body)
        self.assertIn('if [ "$rc" -ne 0 ]', body)

    def test_marker_does_not_weaken_other_workspace_commands(self):
        self.assertEqual(SCRIPT.count(
            "MACWS_UTILITY_PROCESS=1 /var/jb/usr/bin/timeout -k 2 20"), 2)

    def test_wallpaper_is_applied_before_the_dock_space_rebind(self):
        for start, end in (
                ("start_ws_dependents_after_replacement()", "\nrecover_ws_dependents()"),
                ("start_macos()", "\nstop_all()")):
            body = SCRIPT[SCRIPT.index(start):SCRIPT.index(end)]
            ensure = body.index("ensure_navigation_spaces || return 1")
            wallpaper = body.index("apply_workspace_wallpaper || return 1", ensure)
            rebind = body.index("refresh_dock_after_navigation_spaces || return 1", ensure)
            self.assertLess(ensure, wallpaper)
            self.assertLess(wallpaper, rebind)


if __name__ == "__main__":
    unittest.main()
