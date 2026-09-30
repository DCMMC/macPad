"""Source contract for passive fullscreen catalog and explicit app selection.

The visual acceptance is a live Stray launch with a Host/iPadOS screenshot;
this test only guards the identity boundary that previously oscillated.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HOST = (ROOT / "MacWSHost/main.m").read_text()
VIEW = (ROOT / "MacWSHost/Rendering/MacWSMetalView.m").read_text()
HEADER = (ROOT / "MacWSHost/Rendering/MacWSMetalView.h").read_text()
COMPOSITOR = (ROOT / "MacWSHost/Rendering/MacWSCatalystDrawableCompositor.m").read_text()


class FullscreenDrawableTargetContract(unittest.TestCase):
    def test_explicit_fullscreen_window_survives_cold_catalog_connection(self):
        route = HOST.split(
            "- (BOOL)activateMacWindowIDInFullscreenWorkspace:", 1
        )[1].split("- (void)performSemanticShortcutForDiagnostics:", 1)[0]
        self.assertIn("_pendingFullscreenActivationWindowID = windowID", route)
        self.assertIn("_pendingFullscreenActivationOwnerPID = ownerPID", route)
        self.assertIn("CACurrentMediaTime() + 10.0", route)

        catalog = HOST.split(
            "- (void)metalView:(MacWSMetalView *)view\n  receivedWindows:", 1
        )[1].split("// An explicit activation carries", 1)[0]
        match = catalog.index("fullscreen-window-route matched")
        selection = catalog.index("frontmostInputApplicationPIDAmongPIDs")
        self.assertLess(match, selection)
        self.assertIn("[self activateMacWindow:requested]", catalog)
        self.assertIn("fullscreen-window-route expired", catalog)

    def test_completed_drawable_is_only_a_passive_catalog_retention(self):
        selector = HOST.split("- (void)metalView:(MacWSMetalView *)view\n  receivedWindows:", 1)[1]
        selector = selector.split("// An explicit activation carries", 1)[0]
        self.assertIn("_fullscreenActivatedInputOwnerPID == previousPID", selector)
        self.assertIn("[_metalView hasCompletedFullscreenDrawableForPID:previousPID]", selector)
        self.assertIn("retainedPreviousTarget || activatedFullscreenCanvasPresent ||", selector)
        self.assertLess(selector.index("retainedPreviousTarget || activatedFullscreenCanvasPresent ||"),
                        selector.index("_metalView.targetPID = targetPID"))
        self.assertIn("_fullscreenActivatedInputOwnerPID = window.descriptor.ownerPID", HOST)

    def test_first_frame_race_is_covered_before_drawable_arrives(self):
        selector = HOST.split("- (void)metalView:(MacWSMetalView *)view\n  receivedWindows:", 1)[1]
        selector = selector.split("// An explicit activation carries", 1)[0]
        self.assertIn("MacWSStreamWindowFocused |", selector)
        self.assertIn("MacWSStreamWindowFullscreenCanvas", selector)
        self.assertIn("descriptor.ownerPID == previousPID", selector)
        self.assertIn("activatedFullscreenCanvasPresent = YES", selector)
        self.assertNotIn("frame.texture", selector)

    def test_drawable_witness_needs_real_canvas_and_process(self):
        self.assertIn("hasCompletedFullscreenDrawableForPID:", HEADER)
        method = VIEW.split("- (BOOL)hasCompletedFullscreenDrawableForPID:", 1)[1]
        method = method.split("\n}\n", 1)[0]
        for witness in ("ownerPID != self.targetPID",
                        "_fullscreenCanvasPIDs containsObject:@(ownerPID)",
                        "MacWSAppInputEndpointReady(ownerPID)",
                        "frameForOwnerPID:ownerPID", "frame.texture",
                        "MacWSStreamWindowFocused",
                        "MacWSStreamWindowFullscreenCanvas"):
            self.assertIn(witness, method)

    def test_one_transferred_surface_lease_has_one_active_scene_consumer(self):
        callback = VIEW.split(
            "- (void)catalystDrawableDidPresent:", 1)[1].split(
            "- (NSString *)exportCatalystDrawableProbeForPID:", 1)[0]
        self.assertIn("if (!_acceptsCatalystDrawables) return;", callback)

        configure = VIEW.split("- (void)configureStreamMode:", 1)[1].split(
            "- (uint64_t)inputSceneIDWithModifiers:", 1)[0]
        self.assertIn("_acceptsCatalystDrawables = YES;", configure)
        suspend = VIEW.split("- (void)suspendStream {", 1)[1].split(
            "- (uint32_t)currentFrameWidth", 1)[0]
        self.assertIn("_acceptsCatalystDrawables = NO;", suspend)
        self.assertIn("[_catalystDrawableCompositor removeAllFrames];", suspend)
        self.assertLess(suspend.index("_acceptsCatalystDrawables = NO;"),
                        suspend.index("[_streamClient unsubscribe]"))

        consume = COMPOSITOR.split("- (MacWSCatalystDrawableFrame *)consumeDeliveryObject:", 1)[1].split(
            "- (MacWSCatalystDrawableFrame *)frameForOwnerPID:", 1)[0]
        self.assertIn("delivery.isAccepted", consume)
        self.assertIn("delivery.accepted = YES", consume)
        receiver = (ROOT / "MacWSHost" / "Transport" /
                    "MacWSCatalystDrawableReceiver.m").read_text()
        self.assertIn("MacWSCatalystDrawableDelivery *delivery", receiver)
        self.assertNotIn("NSData *payload", receiver)

    def test_fullscreen_hit_test_uses_rendered_drawable_before_hidden_desktop(self):
        authority = VIEW.split(
            "- (MacWSCatalystDrawableFrame *)authoritativeFullscreenDrawableFrame {", 1
        )[1].split("\n}\n", 1)[0]
        for witness in (
            "_surfaceFrame", "_surfaceTexture", "_opaquePipeline",
            "_directDrawableHeartbeatPID != self.targetPID",
            "_reportedFullscreenCanvasWindowID !=",
            "MacWSAppInputEndpointReady(self.targetPID)",
            "frame.texture ? frame : nil",
        ):
            self.assertIn(witness, authority)
        render = VIEW.split("- (void)drawInMTKView:", 1)[1].split(
            "- (BOOL)resolveFullscreenLayerAtPoint:", 1
        )[0]
        hit_test = VIEW.split("- (BOOL)resolveFullscreenLayerAtPoint:", 1)[1].split(
            "- (BOOL)performanceVisiblePointForTargetPID:", 1
        )[0]
        self.assertIn("[self authoritativeFullscreenDrawableFrame]", render)
        self.assertIn("[self authoritativeFullscreenDrawableFrame]", hit_test)
        self.assertLess(
            hit_test.index("[self authoritativeFullscreenDrawableFrame]"),
            hit_test.index("[self resolveFinalCompositeCatalogAtPoint:"),
        )
        self.assertIn("!CGRectContainsPoint(canvas, point)", hit_test)
        self.assertIn("if (pidOut) *pidOut = self.targetPID", hit_test)

    def test_target_direct_drawable_owns_input_visibility_sample(self):
        monitor = (ROOT / "MacWSHost/MacWSPerformanceMonitor.m").read_text()
        direct = monitor.split(
            "- (void)recordDirectDrawableSubmissionForOwnerPID:", 1
        )[1].split("- (void)recordSubmissionForStream:", 1)[0]
        for witness in (
            "isTarget && _pendingInputMachTime",
            "completionTime >= _pendingInputMachTime",
            "_pendingInputTargetPID == ownerPID",
            "inputMachTime = _pendingInputMachTime",
            "MacWSPerfRingAppend(&strongSelf->_inputToPresent, latency)",
            "strongSelf->_directInputVisibilitySamples++",
        ):
            self.assertIn(witness, direct)

        self.assertIn(
            '@"composited_input_visibility_samples"', monitor
        )
        self.assertIn(
            '@"direct_input_visibility_samples"', monitor
        )

        render = VIEW.split("- (void)drawInMTKView:", 1)[1].split(
            "- (BOOL)resolveFullscreenLayerAtPoint:", 1
        )[0]
        direct_call = render.rindex(
            "recordDirectDrawableSubmissionForOwnerPID:performanceOwnerPID"
        )
        self.assertIn("performanceOwnerPID = record.ownerPID", render)
        base_call = render.rindex(
            "recordSubmissionForStream:performanceStreamID"
        )
        self.assertLess(direct_call, base_call)

        base = monitor.split(
            "- (void)recordSubmissionForStream:", 1
        )[1].split("- (NSDictionary<NSString *, id> *)snapshotWithReason:", 1)[0]
        self.assertIn(
            "if (!directTargetAuthoritative &&", base
        )
        self.assertIn(
            "(_finalCompositeActive &&", base
        )
        self.assertIn(
            "directTargetAuthoritative:(fullscreenDirectAuthoritative ||",
            render,
        )

        route = VIEW.split(
            "- (BOOL)routeFullscreenInputRecord:", 1
        )[1].split("- (void)handleTouch:", 1)[0]
        self.assertIn("BOOL directVisualAuthority", route)
        self.assertIn(
            "[self authoritativeFullscreenDrawableFrame] != nil", route
        )
        self.assertIn(
            "!directVisualAuthority ? dockPID : visualPID", route
        )


if __name__ == "__main__":
    unittest.main()
