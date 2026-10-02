import pathlib
import re
import struct
import tempfile
import unittest
from unittest import mock

import host_input_matrix


ROOT = pathlib.Path(__file__).resolve().parents[1]
METAL_VIEW = (ROOT / "MacWSHost" / "Rendering" /
              "MacWSMetalView.m").read_text()
APP_INPUT = (ROOT / "libmachook" / "AppInputBridge.m").read_text()
INPUTD = (ROOT / "macwsinputd" / "main.c").read_text()
MAC_HOOKS = (ROOT / "libmachook" / "mac_hooks.m").read_text()
HOSTD = (ROOT / "macwshostd" / "main.m").read_text()
EXEC_HOOKS = (ROOT / "libmachook" / "exec_hooks.c").read_text()
POSTINST = (ROOT / "layout" / "usr" / "macOS" / "bin" /
            "postinst.sh").read_text()
DEBIAN_POSTINST = (ROOT / "layout" / "DEBIAN" / "postinst").read_text()
CLI_CONFIG = (ROOT / "layout" / "usr" / "macOS" / "bin" /
              "configure_terminal_cli.sh").read_text()


class HardwareKeyboardContractTests(unittest.TestCase):
    def test_terminal_keys_have_key_command_fallbacks(self):
        for symbol in (
            "UIKeyInputEscape",
            "UIKeyInputDelete",
            "UIKeyInputUpArrow",
            "UIKeyInputDownArrow",
            "UIKeyInputLeftArrow",
            "UIKeyInputRightArrow",
            "UIKeyInputPageUp",
            "UIKeyInputPageDown",
            "UIKeyInputHome",
            "UIKeyInputEnd",
        ):
            self.assertIn(symbol, METAL_VIEW)
        self.assertIn("append(input, UIKeyModifierControl);", METAL_VIEW)

    def test_named_inputs_keep_appkit_keysyms(self):
        expected = {
            "UIKeyInputEscape": "0xff1b",
            "UIKeyInputDelete": "0xff08",
            "UIKeyInputUpArrow": "0xff52",
            "UIKeyInputDownArrow": "0xff54",
            "UIKeyInputLeftArrow": "0xff51",
            "UIKeyInputRightArrow": "0xff53",
        }
        for input_name, keysym in expected.items():
            self.assertRegex(
                METAL_VIEW,
                re.escape(f"[input isEqualToString:{input_name}]") +
                r"\)\s+keySym\s*=\s*" + re.escape(keysym) + r";",
            )

    def test_navigation_fallbacks_keep_physical_appkit_keycodes(self):
        expected = {
            "0xff50": "115",  # Home
            "0xff55": "116",  # Page Up
            "0xff56": "121",  # Page Down
            "0xff57": "119",  # End
        }
        for keysym, keycode in expected.items():
            self.assertRegex(
                METAL_VIEW,
                re.escape(f"case {keysym}: keyCode = {keycode}; break;"),
            )

    def test_control_characters_are_translated_without_losing_keycode(self):
        self.assertIn("MacWSCharactersApplyingControl", APP_INPUT)
        self.assertIn("scalar &= 0x1f", APP_INPUT)
        self.assertIn("MacWSCharactersForRFBKeySym(keySym, YES)", APP_INPUT)
        self.assertIn("!controlModified && setCGEventUnicode", APP_INPUT)
        self.assertIn("modifiers |= 0x100u;", APP_INPUT)

    def test_window_discovery_accepts_current_v3_metrics(self):
        header = struct.pack("<IHHIIQ", 0x4D57474D, 3, 24, 56, 1, 9)
        entry = struct.pack("<II", 521, 0) + bytes(48)
        with tempfile.NamedTemporaryFile() as metrics:
            metrics.write(header + entry)
            metrics.flush()
            real_open = open

            def open_metrics(path, mode="r", *args, **kwargs):
                if path.endswith("macws_window_metrics.87221.bin"):
                    path = metrics.name
                return real_open(path, mode, *args, **kwargs)

            with mock.patch("builtins.open", side_effect=open_metrics):
                self.assertEqual(host_input_matrix.resolve_window(87221, 0),
                                 521)

    def test_physical_keys_select_exact_app_or_global_session_route(self):
        self.assertIn("nativeKeyboardProxyRecord", INPUTD)
        self.assertIn("MacWSInputSourceHardwareKeyboard", INPUTD)
        self.assertIn("MacWSInputWindowIDForScene(record->sceneID) == 0",
                      INPUTD)
        self.assertIn("MacWSAppInputKeyboardApplication", APP_INPUT)
        self.assertIn("stage=app-queue", APP_INPUT)
        self.assertIn("stage=app-cgs-post", APP_INPUT)
        self.assertIn("MacWSMainBundleIsSevenDaysToDie()", APP_INPUT)
        self.assertIn("keySym <= 0xffu", APP_INPUT)
        self.assertIn("macws_vnc_proxy_keyboard", MAC_HOOKS)
        self.assertIn("CGEventCreateKeyboardEvent", MAC_HOOKS)
        self.assertIn("kCGSessionEventTap", MAC_HOOKS)

    def test_gui_launches_do_not_inherit_daemon_signal_mask(self):
        self.assertIn("posix_spawnattr_setsigmask", HOSTD)
        self.assertIn("posix_spawnattr_setsigdefault", HOSTD)
        self.assertIn("POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF",
                      HOSTD)
        for signal_name in ("SIGINT", "SIGQUIT", "SIGTSTP", "SIGTTIN",
                            "SIGTTOU"):
            self.assertIn(signal_name, HOSTD)

    def test_managed_cli_path_precedes_legacy_usr_local(self):
        preferred = "/opt/local/bin:/opt/local/sbin:/usr/local/bin"
        self.assertIn(f'"PATH={preferred}:"', EXEC_HOOKS)
        self.assertIn(f"export PATH={preferred}:", CLI_CONFIG)
        self.assertIn("TERMINAL_CLI_ENV_MARKER", CLI_CONFIG)
        helper = "bash /var/jb/usr/macOS/bin/configure_terminal_cli.sh"
        self.assertIn(helper, POSTINST)
        self.assertIn(helper, DEBIAN_POSTINST)

    def test_neofetch_uses_single_process_fast_path(self):
        self.assertIn(
            "alias neofetch='command /usr/local/bin/macws-neofetch'",
            CLI_CONFIG,
        )
        fast_source = (ROOT / "macwsneofetch" / "main.c").read_text()
        self.assertIn('"/opt/local/bin/neofetch"', fast_source)
        self.assertIn('host_statistics64', fast_source)
        self.assertIn('sysctlbyname("kern.boottime"', fast_source)
        self.assertIn("macws-neofetch", POSTINST)
        self.assertIn("macws-neofetch", DEBIAN_POSTINST)
        root_makefile = (ROOT / "Makefile").read_text()
        self.assertIn("macwsneofetch", root_makefile)
        build_on_ios = (ROOT / "misc" / "build_on_ios.sh").read_text()
        self.assertIn("macwsworkspacectl macwsneofetch", build_on_ios)


if __name__ == "__main__":
    unittest.main()
