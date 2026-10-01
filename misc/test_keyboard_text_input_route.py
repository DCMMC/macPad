"""Execute the Magic Keyboard routing policy used while UIKit IME is active."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class KeyboardTextInputRouteTests(unittest.TestCase):
    def test_framework_free_hid_policy(self):
        compiler = shutil.which("clang") or shutil.which("cc")
        if not compiler:
            self.skipTest("C compiler unavailable")
        program = r'''
#include "macws_keyboard_text_input.h"
#include <assert.h>

int main(void) {
    for (unsigned usage = 74; usage <= 82; ++usage) {
        assert(MacWSHardwareKeyRequiresMacRouteDuringTextInput(usage, 0));
        assert(MacWSHardwareKeyRequiresMacRouteDuringTextInput(
            usage, MacWSUIKitModifierShift));
    }
    for (unsigned usage = 224; usage <= 231; ++usage) {
        assert(!MacWSHardwareKeyRequiresMacRouteDuringTextInput(
            usage, MacWSUIKitModifierControl | MacWSUIKitModifierCommand));
    }
    for (unsigned usage = 4; usage <= 56; ++usage) {
        assert(!MacWSHardwareKeyRequiresMacRouteDuringTextInput(usage, 0));
        assert(!MacWSHardwareKeyRequiresMacRouteDuringTextInput(
            usage, MacWSUIKitModifierShift));
        assert(MacWSHardwareKeyRequiresMacRouteDuringTextInput(
            usage, MacWSUIKitModifierControl));
        assert(MacWSHardwareKeyRequiresMacRouteDuringTextInput(
            usage, MacWSUIKitModifierCommand) ==
            (usage != 43 && usage != 44));
    }
    assert(!MacWSHardwareKeyRequiresMacRouteDuringTextInput(
        43, MacWSUIKitModifierCommand)); // Command-Tab
    assert(!MacWSHardwareKeyRequiresMacRouteDuringTextInput(
        44, MacWSUIKitModifierCommand)); // Command-Space
    assert(MacWSHardwareKeyRequiresMacRouteDuringTextInput(
        44, MacWSUIKitModifierControl)); // Control-Space
    assert(!MacWSHardwareKeyRequiresMacRouteDuringTextInput(
        4, MacWSUIKitModifierAlternate));
    return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix="macws-ime-hardware-route-") as tmp:
            path = Path(tmp)
            source = path / "probe.c"
            binary = path / "probe"
            source.write_text(program)
            subprocess.run(
                [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                 "-fsanitize=undefined", "-I", str(ROOT / "include"),
                 str(source), "-o", str(binary)],
                check=True,
                capture_output=True,
            )
            subprocess.run([str(binary)], check=True, timeout=5)

    def test_window_keeps_ime_text_but_routes_shortcuts(self):
        source = (ROOT / "MacWSHost" / "main.m").read_text()
        start = source.index(
            "- (BOOL)forwardHardwarePressEvent:(UIPressesEvent *)event {"
        )
        end = source.index("\n- (void)observeHardwareModifiersForEvent:", start)
        route = source[start:end]
        self.assertNotIn(
            "_keyboardProxy.isFirstResponder || _appSearchField.isFirstResponder",
            route,
        )
        self.assertIn(
            "MacWSHardwareKeyRequiresMacRouteDuringTextInput(", route
        )
        self.assertIn('textInputActive ? @"YES" : @"NO"', route)

        observer_start = source.index(
            "- (void)observeHardwareModifiersForEvent:(UIEvent *)event {"
        )
        observer_end = source.index(
            "\n- (void)releaseHardwareKeyboardState", observer_start
        )
        observer = source[observer_start:observer_end]
        self.assertNotIn("_keyboardProxy.isFirstResponder ||", observer)
        self.assertIn("[_metalView observeHardwareModifiersForEvent:event]", observer)


if __name__ == "__main__":
    unittest.main()
