"""Semantic menu and Dock quit requests use public AppKit lifecycle."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP_INPUT = (ROOT / "libmachook" / "AppInputBridge.m").read_text()


class AppQuitContract(unittest.TestCase):
    def test_perform_quit_uses_public_cooperative_action(self):
        handler = APP_INPUT.split(
            "static void MacWSHandlePerformQuit(id application) {", 1
        )[1].split("static void MacWSPostInputOnMainThread", 1)[0]
        self.assertIn('sel_registerName("terminate:")', handler)
        self.assertIn("MacWSMsgVoidID", handler)
        self.assertNotIn('sel_registerName("_handleAEQuit")', handler)
        self.assertNotIn("kill(", handler)

    def test_preexisting_auxiliary_is_closed_cooperatively_before_retry(self):
        handler = APP_INPUT.split(
            "static void MacWSHandlePerformQuit(id application) {", 1
        )[1].split("static void MacWSPostInputOnMainThread", 1)[0]
        self.assertIn("MacWSPresentingWindow(candidate, application)", handler)
        self.assertIn('sel_registerName("modalWindow")', handler)
        self.assertIn("MacWSTransientWindowAssociationKey", handler)
        self.assertIn('sel_registerName("performClose:")', handler)
        self.assertIn("if (closeCommitted)", handler)
        self.assertGreaterEqual(
            handler.count("application, terminate, nil"), 2
        )
        self.assertLess(
            handler.index("if (supported && auxiliaryWindow)"),
            handler.index('"#### APP-INPUT PERFORM-QUIT pid=%d "'),
        )
        publisher = APP_INPUT.split(
            "static void MacWSPublishWindowMetrics(void) {", 1
        )[1].split("static BOOL MacWSMenuItemIsSeparator", 1)[0]
        self.assertIn("MacWSTransientWindowAssociationKey", publisher)
        self.assertIn("transient ? @YES : nil", publisher)

    def test_wire_record_still_routes_to_semantic_handler(self):
        router = APP_INPUT.split(
            "static void MacWSPostInputOnMainThread", 1
        )[1]
        self.assertIn("record.kind == MacWSInputKindPerformQuit", router)
        self.assertIn("MacWSHandlePerformQuit(application);", router)

    def test_modal_quit_uses_main_dispatch_without_duplicate_fifo_delivery(self):
        receiver = APP_INPUT.split(
            "static void *MacWSAppInputThread(void *unused) {", 1
        )[1].split("// Runs on the application main thread.", 1)[0]
        direct = receiver.split(
            "if (record.kind == MacWSInputKindPerformQuit) {", 1
        )[1].split("// During a real NSControl tracking loop", 1)[0]
        self.assertIn("dispatch_async(dispatch_get_main_queue()", direct)
        self.assertIn('CFSTR("NSModalPanelRunLoopMode")', direct)
        self.assertIn('CFSTR("NSEventTrackingRunLoopMode")', direct)
        self.assertIn("kCFRunLoopDefaultMode", direct)
        self.assertIn("__block BOOL delivered = NO", direct)
        self.assertIn("MacWSPostInputOnMainThread(record);", direct)
        self.assertIn("continue;", direct)
        self.assertNotIn("MacWSEnqueueAppInputRecord(record)", direct)


if __name__ == "__main__":
    unittest.main()
