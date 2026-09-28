#!/usr/bin/env python3
"""Source invariants for the isolated uid-501 CFPreferences login agent."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
GUI = (ROOT / "layout/usr/macOS/bin/macos_gui.sh").read_text()
HOOKS = (ROOT / "libmachook/mac_hooks.m").read_text()
METAL_HOOKS = (ROOT / "libmachook/Metal_hooks.x").read_text()


class MobileCFPreferencesAgentTests(unittest.TestCase):
    def test_root_and_mobile_agents_publish_distinct_endpoints(self):
        self.assertIn(
            "com.apple.macosbooter.cfprefsd.agent</key><true/>", GUI
        )
        self.assertIn(
            "com.apple.macosbooter.cfprefsd.agent.501</key><true/>", GUI
        )
        self.assertIn(
            '<string>${CHROOTEXEC}</string><string>501</string><string>501</string>',
            GUI,
        )

    def test_mobile_identity_and_routing_are_exactly_scoped(self):
        route = HOOKS.split(
            'if (!strcmp(name, "com.apple.cfprefsd.agent"))', 1
        )[1].split('if (!strcmp(name, "com.apple.audio.AudioComponentRegistrar"))', 1)[0]
        self.assertIn("geteuid() == 501", route)
        self.assertIn('strcmp(mobileIdentity, "1") == 0', route)
        self.assertIn('return "com.apple.macosbooter.cfprefsd.agent.501";', route)
        self.assertIn('return "com.apple.macosbooter.cfprefsd.agent";', route)

        shared_cache_route = METAL_HOOKS.split(
            "static const char *macws_private_chroot_service_name", 1
        )[1].split(
            'if (!strcmp(name, "com.apple.audio.AudioComponentRegistrar"))', 1
        )[0]
        self.assertIn("geteuid() == 501", shared_cache_route)
        self.assertIn(
            'return "com.apple.macosbooter.cfprefsd.agent.501";',
            shared_cache_route,
        )
        self.assertIn(
            'return "com.apple.macosbooter.cfprefsd.agent";',
            shared_cache_route,
        )

        identity = HOOKS.split(
            "static bool macws_synthetic_mobile_user_enabled", 1
        )[1].split("static id (*macws_lsd_database_store_url_orig)", 1)[0]
        self.assertIn("geteuid() == 501", identity)
        self.assertIn('enabled && strcmp(enabled, "1") == 0', identity)
        self.assertIn('.pw_dir = "/Users/mobile"', identity)
        self.assertIn('"/var/folders/zz/macws_uid501/0/"', HOOKS)
        self.assertIn('"/var/folders/zz/macws_uid501/C/"', HOOKS)
        self.assertIn('"/var/folders/zz/macws_uid501/T/"', HOOKS)

        session = HOOKS.split("static void *vproc_swap_string_new", 1)[1].split(
            "static size_t macws_confstr_new", 1
        )[0]
        self.assertIn("macws_is_private_cfprefsd_agent()", session)
        self.assertNotIn("macws_synthetic_mobile_user_enabled()", session)
        self.assertIn('strdup("Background")', session)

    def test_startup_requires_a_real_uid501_write_read_round_trip(self):
        probe = GUI.split("verify_mobile_preferences_persistence()", 1)[1].split(
            "apply_workspace_wallpaper()", 1
        )[0]
        self.assertIn("run_mobile_defaults_utility write", probe)
        self.assertIn("run_mobile_defaults_utility read", probe)
        self.assertIn("[ \"$value\" != 1 ]", probe)
        self.assertNotIn("run_mobile_defaults_utility write || true", probe)
        self.assertNotIn("run_mobile_defaults_utility read || true", probe)

    def test_atomic_write_directories_keep_per_uid_ownership(self):
        tree = GUI.split("ensure_cfprefsd_dirhelper_tree()", 1)[1].split(
            "ensure_launchservices_session_user_dir()", 1
        )[0]
        self.assertIn('root_home="$ROOTFS/private/var/root"', tree)
        self.assertIn('root_preferences="$root_library/Preferences"', tree)
        self.assertIn(
            'chown root:wheel "$temporary_root" "$temporary_user" "$temporary_leaf"',
            tree,
        )
        self.assertIn(
            'chmod 0700 "$root_home" "$root_library" "$root_preferences"',
            tree,
        )
        self.assertIn('temporary_mobile="$temporary_root/folders.501"', tree)
        self.assertIn('chown 501:501 "$temporary_mobile"', tree)
        self.assertIn('chmod 0700 "$temporary_mobile" "$temporary_mobile_leaf"', tree)
        self.assertIn('chmod 0755 "$mobile_home" "$mobile_library"', tree)
        self.assertIn('mobile_user_root="$ROOTFS/var/folders/zz/macws_uid501"', tree)
        self.assertIn('chmod 0700 "$mobile_user_root" "$mobile_user_dir"', tree)

    def test_in_place_desktop_repair_rebuilds_the_atomic_write_tree(self):
        repair = GUI.split("repair_desktop()", 1)[1].split(
            "rebuild_desktop_session()", 1
        )[0]
        self.assertIn("ensure_cfprefsd_dirhelper_tree", repair)
        self.assertLess(
            repair.index("ensure_cfprefsd_dirhelper_tree"),
            repair.index('ensure_desktop_job "$CFPREFSD_DAEMON_PLIST"'),
        )


if __name__ == "__main__":
    unittest.main()
