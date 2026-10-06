"""Static contracts for the iPadOS pointer-lock -> AppKit relative route."""

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class GamePointerLockContractTests(unittest.TestCase):
    def test_host_fails_closed_until_uikit_confirms_lock(self):
        main = (ROOT / "MacWSHost/main.m").read_text()
        view = (ROOT / "MacWSHost/Rendering/MacWSMetalView.m").read_text()
        makefile = (ROOT / "MacWSHost/Makefile").read_text()

        self.assertIn("prefersPointerLocked", main)
        self.assertIn("UIPointerLockStateDidChangeNotification", main)
        self.assertIn("scene.pointerLockState.isLocked", main)
        self.assertIn("MacWSHostInputModeGame", main)
        self.assertIn('@"input-game"', main)
        self.assertIn("[self inputModeChanged:_inputModeControl]", main)
        self.assertIn("GameController", makefile)
        self.assertIn("mouse.mouseInput.mouseMovedHandler", view)
        self.assertIn("[self gamePointerCaptureReady]", view)
        self.assertIn("MacWSInputKindRelativePointer", view)
        self.assertIn("MacWSInputSceneForWindow(windowID, 0)", view)
        self.assertIn(
            "MacWSMetalView *previousOwner = MacWSGamePointerOwner;", view
        )
        self.assertRegex(
            view,
            r"if \(previousOwner != self\) \{\s+if \(previousOwner\) \{",
        )

    def test_relative_diagnostics_do_not_require_global_agx_recorders(self):
        diagnostics = (
            ROOT / "MacWSHost/Support/MacWSHostDiagnostics.m"
        ).read_text()
        view = (ROOT / "MacWSHost/Rendering/MacWSMetalView.m").read_text()
        main = (ROOT / "MacWSHost/main.m").read_text()
        broker = (ROOT / "macwsinputd/main.c").read_text()
        app = (ROOT / "libmachook/AppInputBridge.m").read_text()

        marker = "macws_game_pointer_diagnostics"
        self.assertIn(marker, diagnostics)
        self.assertIn(marker, broker)
        self.assertIn(marker, app)
        self.assertIn("MacWSHostGamePointerDiagnosticsEnabled()", view)
        self.assertIn("MacWSHostGamePointerDiagnosticsEnabled()", main)
        self.assertIn("GamePointerDiagnosticsEnabled()", broker)
        self.assertIn("MacWSGamePointerDiagnosticsEnabled()", app)

    def test_relative_route_never_falls_back_to_global_cursor(self):
        broker = (ROOT / "macwsinputd/main.c").read_text()
        app = (ROOT / "libmachook/AppInputBridge.m").read_text()

        self.assertIn("bool relativePointerRecord", broker)
        self.assertIn("if (relativePointerRecord) {", broker)
        self.assertIn("has no meaningful global-cursor", broker)
        self.assertIn("MacWSCreateAppRelativePointerEvent", app)
        self.assertIn("kCGMouseEventDeltaX", app)
        self.assertIn("kCGMouseEventDeltaY", app)
        self.assertIn('sel_registerName("deltaX")', app)
        self.assertIn('sel_registerName("deltaY")', app)
        self.assertIn("last.pressure + record.pressure", app)
        self.assertIn("last.altitude + record.altitude", app)
        self.assertRegex(
            app,
            r"candidate\.kind == MacWSInputKindScroll \|\|\s+"
            r"candidate\.kind == MacWSInputKindRelativePointer",
        )

    def test_vertical_conversion_and_finger_relative_route_are_explicit(self):
        view = (ROOT / "MacWSHost/Rendering/MacWSMetalView.m").read_text()
        broker = (ROOT / "macwsinputd/main.c").read_text()
        app = (ROOT / "libmachook/AppInputBridge.m").read_text()

        self.assertIn("deltaY:-dy", view)
        self.assertIn("coalescedTouchesForTouch:_trackpadTouch", view)
        self.assertIn("source:MacWSInputSourceFinger", view)
        self.assertIn("self.inputMode == MacWSHostInputModeGame", view)
        self.assertRegex(
            broker,
            r"record->source == MacWSInputSourceIndirectPointer \|\|\s+"
            r"record->source == MacWSInputSourceFinger",
        )
        self.assertRegex(
            app,
            r"record->source == MacWSInputSourceIndirectPointer \|\|\s+"
            r"record->source == MacWSInputSourceFinger",
        )

    def test_automatic_mode_follows_application_relative_mouse_request(self):
        protocol = (ROOT / "include/macws_stream_protocol.h").read_text()
        app = (ROOT / "libmachook/AppInputBridge.m").read_text()
        display = (ROOT / "macwsdisplayd/main.m").read_text()
        main = (ROOT / "MacWSHost/main.m").read_text()

        capability = "MacWSStreamWindowRelativePointerRequested"
        self.assertIn(capability, protocol)
        self.assertIn("MacWSAssociateMouseAndMouseCursorPosition", app)
        self.assertIn("CGAssociateMouseAndMouseCursorPosition(connected)", app)
        self.assertIn("MacWSDisplayHideCursor", app)
        self.assertIn("MacWSDisplayShowCursor", app)
        self.assertIn("MacWSGetLastMouseDelta", app)
        self.assertIn("hidden-delta-consumer", app)
        self.assertIn("hidden-delta-expiry", app)
        self.assertIn("if (depth == 0) return;", app)
        self.assertIn("MacWSInstallUnityRelativePointerContract", app)
        self.assertIn(
            "MacWSScheduleUnityRelativePointerContractInstall", app
        )
        self.assertIn("attempt < 39", app)
        self.assertIn('objc_getClass("PlayerWindowView")', app)
        self.assertIn('objc_getClass("UnityView")', app)
        self.assertIn('sel_registerName("setShowCursor:")', app)
        self.assertIn('strcmp(encoding, "v20@0:8B16")', app)
        self.assertIn(
            "MacWSOriginalUnitySetShowCursor(self, selector, visible)", app
        )
        self.assertIn("PlayerWindowView.setShowCursor(false)", app)
        self.assertIn("MacWSReconcileUnityCursorState(keyWindow)", app)
        self.assertIn('sel_registerName("showCursor")', app)
        self.assertIn('strcmp(encoding, "B16@0:8")', app)
        self.assertIn("MacWSFindUnityPlayerView", app)
        self.assertIn("MacWSFindUnityPlayerResponder", app)
        self.assertIn("firstResponder, unityViewClass", app)
        self.assertIn("RELATIVE-UNITY-LOOKUP", app)
        self.assertIn("MacWSInstallUnityViewEventHook", app)
        self.assertIn('"v24@0:8@16"', app)
        for selector in (
            "mouseDown:", "mouseUp:", "mouseMoved:", "keyDown:", "keyUp:"
        ):
            self.assertIn(f'"{selector}"', app)
        self.assertIn("MacWSReconcileUnityViewAndPublish", app)
        self.assertIn("RELATIVE-UNITY-EVENT", app)
        self.assertIn("if (!pthread_main_np())", app)
        self.assertIn("NSUInteger budget = 256", app)
        self.assertIn("MacWSUnityCursorStateKnown", app)
        self.assertIn("previousKnown == known", app)
        self.assertIn("PlayerWindowView.showCursor-state", app)
        self.assertIn("PlayerWindowView-not-key-window", app)
        self.assertIn("MacWSRelativePointerRequestGeneration", app)
        self.assertIn("MacWSRelativePointerPublishedGeneration", app)
        self.assertIn("relativeEventWindow", app)
        self.assertIn(
            "MacWSReconcileUnityCursorState(relativeEventWindow)", app
        )
        self.assertIn(
            "relativeRequestGeneration != relativePublishedGeneration", app
        )
        self.assertIn("relativeContractRepresented", app)
        self.assertIn(
            "MacWSSetRelativePointerRequestedAndPublish(", app
        )
        self.assertIn(
            "associated || unityCursorHidden || consumingDeltas", app
        )
        self.assertIn("relativePointerRequested && window == keyWindow", app)
        self.assertIn(capability, display)
        self.assertIn("relativePointerRequestWindowInWindows", main)
        self.assertIn("updateAutomaticGameInputForWindows", main)
        self.assertIn("automatic:YES persist:NO", main)
        self.assertIn("automatic:NO persist:NO", main)

    def test_existing_input_modes_and_m1_wire_compatibility_remain(self):
        protocol = (ROOT / "include/macws_host_protocol.h").read_text()

        self.assertIn("MacWSHostInputModeDirect = 1", protocol)
        self.assertIn("MacWSHostInputModeTrackpad = 2", protocol)
        self.assertIn("MacWSHostInputModeGame = 3", protocol)
        self.assertIn("MACWS_INPUT_KEYBOARD_VERSION 8u", protocol)
        self.assertIn("version == MACWS_INPUT_KEYBOARD_VERSION", protocol)
        self.assertIn("MacWSInputKindRelativePointer = 27", protocol)

    def test_absolute_clicks_keep_appkit_geometry_across_direct_scaling(self):
        view = (ROOT / "MacWSHost/Rendering/MacWSMetalView.m").read_text()
        viewport_math = (ROOT / "include/macws_viewport_math.h").read_text()

        self.assertIn("_authoritativeInputGeometryPID", view)
        self.assertIn("retainAuthoritativeInputGeometryForPID", view)
        self.assertIn("source=validated-catalog", view)
        self.assertIn("currentInputFrameWidth", view)
        self.assertIn("pointer-click-map", view)
        self.assertIn("MacWSInputPointInPresentationSpace", view)
        self.assertIn("MacWSMapPixelPointBetweenDomains", view)
        self.assertIn(
            "MacWSMapVisibleSourcePointToDestination", viewport_math
        )
        self.assertIn("fullscreen-direct-pointer-map", view)
        self.assertIn("exactDirectInputGeometry", view)
        self.assertIn("route=exact-app-input", view)
        self.assertIn(
            "record->sceneID = MacWSInputSceneForWindow(", view
        )
        self.assertNotIn(
            "self.window.windowScene.screen.bounds", view
        )
        self.assertNotRegex(
            view,
            r"gamePointerCaptureReady\]\) \{\s+"
            r"framePoint = CGPointMake\(inputWidth \* 0\.5",
        )
        self.assertRegex(
            view,
            r"resolveFullscreenLayerAtPoint:\s*"
            r"presentationPoint pid:&visualPID",
        )


if __name__ == "__main__":
    unittest.main()
