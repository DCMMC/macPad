"""Exercise the production IME composition policy and exact Unicode route."""

import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class TextInputBridgeTests(unittest.TestCase):
    def test_composition_policy(self):
        compiler = shutil.which("clang") or shutil.which("cc")
        if not compiler:
            self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="macws-text-input-") as tmp:
            executable = pathlib.Path(tmp) / "test"
            subprocess.run(
                [
                    compiler,
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-I" + str(ROOT / "include"),
                    str(ROOT / "misc" / "macws_text_input_test.c"),
                    "-o",
                    str(executable),
                ],
                check=True,
            )
            subprocess.run([str(executable)], check=True, timeout=5)

    def test_uikit_proxy_waits_for_marked_text(self):
        host = (ROOT / "MacWSHost" / "main.m").read_text()
        self.assertIn("UIControlEventEditingChanged", host)
        self.assertIn("textField.markedTextRange != nil", host)
        self.assertIn("MacWSKeyboardProxyEditAwaitingComposition", host)
        self.assertIn("emitSoftwareText:committed", host)
        self.assertIn("Let UIKit mutate its real text-input client", host)
        self.assertIn("inputSafe.trailingAnchor", host)
        self.assertIn("systemKeyboardFrameDidChange:", host)
        self.assertIn("fullWidthSoftwareKeyboard ? 0.0 : -144.0", host)
        self.assertIn("@selector(dismissSoftwareKeyboardTapped:)", host)
        self.assertIn("scroll.trailingAnchor constraintEqualToAnchor:dismiss.leadingAnchor", host)
        self.assertIn("[self.view.window endEditing:YES]", host)
        self.assertIn("[self.view bringSubviewToFront:_softwareKeyBar]", host)
        self.assertIn(
            "_controlDismissLayer.bottomAnchor constraintEqualToAnchor:\n"
            "            _softwareKeyBar.topAnchor",
            host,
        )
        self.assertIn("software-toolbar-key keysym=", host)
        self.assertIn("software-toolbar-modifier mask=", host)
        self.assertIn(
            "_softwareKeyBar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor",
            host,
        )

    def test_unicode_commit_keeps_exact_appkit_window(self):
        broker = (ROOT / "macwsinputd" / "main.c").read_text()
        bridge = (ROOT / "libmachook" / "AppInputBridge.m").read_text()
        self.assertIn(
            "return record->source == MacWSInputSourceHardwareKeyboard;",
            broker,
        )
        self.assertIn("exactSoftwareUnicode", bridge)
        self.assertIn('sel_registerName("makeKeyWindow")', bridge)
        self.assertIn("APP-INPUT TEXT-FOCUS", bridge)


if __name__ == "__main__":
    unittest.main()
