"""Source-contract regressions for tab handoff and floating-Dock geometry.

These checks establish implementation invariants only. Visual acceptance is
performed on the target iPad with the full iPadOS composite capture helper.
"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HOST = (ROOT / "MacWSHost/main.m").read_text()
WINDOWING = (ROOT / "MacWSWindowing/Tweak.x").read_text()


def body(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, cursor = 1, opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[opening + 1:cursor - 1]


class TerminalTabHandoffContract(unittest.TestCase):
    def test_same_owner_same_group_handoff_preserves_predecessor(self):
        catalog = body(
            HOST,
            "- (void)metalView:(MacWSMetalView *)view\n  receivedWindows:",
        )
        handoff = catalog[catalog.index("if (resolvedID != _windowID)") :]
        handoff = handoff[:handoff.index("} else if (")]
        self.assertIn("resolvedWindow.descriptor.ownerPID == previousOwnerPID", handoff)
        self.assertIn("resolvedWindow.descriptor.logicalGroupID == previousGroupID", handoff)
        self.assertIn("if (!preserveGroupPredecessor) [_metalView suspendStream]", handoff)
        self.assertLess(handoff.index("preserveGroupPredecessor"),
                        handoff.index("configureStreamMode:MacWSStreamModeWindow"))
        self.assertIn("frame-preserved=%@", handoff)

    def test_cross_window_lifecycle_still_has_real_suspend_paths(self):
        self.assertGreaterEqual(HOST.count("[_metalView suspendStream]"), 5)


class FloatingDockGeometryContract(unittest.TestCase):
    def test_helper_keeps_final_frame_inside_live_dock_exclusion(self):
        helper = body(WINDOWING, "static CGRect MacWSHostFrameAvoidingFloatingDock(")
        self.assertIn("CGRectGetMaxY(containerBounds) - floatingDockHeight", helper)
        self.assertIn("safeBottom = dockTop - minimumDockGap", helper)
        self.assertIn("translatedY = dockTop - dockGap - frame.size.height", helper)
        self.assertIn("frame.origin.y = translatedY", helper)
        self.assertNotIn("frame.size.height =", helper)
        self.assertNotIn("prefersDockHidden", helper)
        self.assertNotIn("return CGRectIntegral(frame)", helper)
        self.assertIn("dockTop - topBoundary - frame.size.height", helper)
        self.assertIn("canFitWithDock", helper)
        self.assertIn("MacWSRequestFloatingDockYield(sceneIdentifier, frame)", helper)

    def test_transient_whole_stage_model_is_adjusted_after_stock_layout(self):
        group = body(
            WINDOWING,
            "- (id)_appLayoutByPerformingAutoLayoutIfNeededInAppLayout:",
        )
        original = group.index("laidOutAppLayout = %orig(")
        adjust = group.index("MacWSAppLayoutByAvoidingFloatingDock(", original)
        self.assertLess(original, adjust)

        model = body(
            WINDOWING, "static id MacWSAppLayoutByAvoidingFloatingDock(",
        )
        self.assertIn('@"com.macwsguide.host"', model)
        self.assertIn("MacWSWorkspaceSinceByScene[scene]", model)
        self.assertIn('@"centerInBounds:"', model)
        self.assertIn('@"attributesByModifyingNormalizedCenter:"', model)
        self.assertIn(
            '@"appLayoutByModifyingLayoutAttributes:forItem:"', model,
        )
        self.assertIn("sizePreserved", model)
        self.assertIn("centerResolved", model)
        self.assertIn(
            "(targetCenter.y - center.y) / containerBounds.size.height",
            model,
        )
        self.assertIn("route=immutable-app-layout", model)

    def test_authoritative_resize_transactions_publish_the_safe_center(self):
        response = body(
            WINDOWING, "- (id)_responseForSceneSizeUpdateToSize:",
        )
        self.assertIn("MacWSHostCenterAvoidingFloatingDock(", response)
        self.assertIn("realGestureResponse", response)
        self.assertIn("matchingGestureFollowup", response)
        self.assertIn("MacWSStableModelSize(selectedScene", response)
        self.assertIn(
            "fabs(stableModelSize.height - constrained.height) <= 1.0",
            response,
        )
        self.assertIn('@"native-resize-response"', response)
        self.assertIn('@"matching-system-followup"', response)
        self.assertIn(
            "%orig(constrained, authoritativeCenter, sceneUpdatesOnly)",
            response,
        )

        programmatic = body(
            WINDOWING,
            "static void MacWSApplyResizeRequest(NSDictionary *request, NSString *path,\n"
            "                                    NSUInteger attempt) {",
        )
        center = programmatic.index("MacWSHostCenterAvoidingFloatingDock(")
        clone = programmatic.index(
            'NSSelectorFromString(\n        @"appLayoutByModifyingLayoutAttributes:forItem:")'
        )
        self.assertLess(center, clone)
        self.assertIn("attributesByModifyingNormalizedCenter:", programmatic)
        self.assertIn("sizePreserved", programmatic)
        self.assertIn("centerResolved", programmatic)
        self.assertIn("route=programmatic-immutable-attributes", programmatic)

    def test_final_switcher_frame_uses_dock_safe_center_without_resizing(self):
        self.assertIn("%hook SBiPadOSPlatformSwitcherModifier", WINDOWING)
        provider = body(WINDOWING, "- (CGRect)frameForIndex:")
        self.assertIn('@"appLayouts"', provider)
        self.assertIn('@"com.macwsguide.host"', provider)
        self.assertIn("MacWSWorkspaceSinceByScene[scene]", provider)
        self.assertIn('@"containerViewBounds"', provider)
        self.assertIn('@"floatingDockHeight"', provider)
        self.assertIn("MacWSHostFrameAvoidingFloatingDock(", provider)
        self.assertIn("CGSizeEqualToSize(original.size, frame.size)", provider)
        self.assertNotIn("frame.size =", provider)
        self.assertNotIn("frame.size.width =", provider)
        self.assertNotIn("frame.size.height =", provider)

    def test_temporary_presentation_setter_diagnostics_are_not_shipped(self):
        self.assertNotIn("%hook SBReusableSnapshotItemContainer", WINDOWING)
        self.assertNotIn("%hook SBDeviceApplicationSceneView", WINDOWING)
        self.assertNotIn("MacWSLogSceneViewGeometry", WINDOWING)
        self.assertNotIn("MacWSLogFrameForIndexProviders", WINDOWING)
        self.assertNotIn("MacWSLogLayoutRoleFrameProvider", WINDOWING)

    def test_repeated_internal_layout_witnesses_are_deduplicated(self):
        model = body(
            WINDOWING, "static id MacWSAppLayoutByAvoidingFloatingDock(",
        )
        self.assertIn("lastAdjusted[scene]", model)
        self.assertIn("lastRejected[scene]", model)
        self.assertIn("MacWSWindowingDiagnosticsEnabled()", model)

    def test_non_authoritative_item_frame_is_not_mutated(self):
        item = body(WINDOWING, "- (CGRect)_frameForLayoutRole:")
        self.assertIn("frame = %orig(", item)
        self.assertNotIn("MacWSHostFrameAvoidingFloatingDock(", item)
        self.assertNotIn("frame.origin", item)

    def test_dock_avoidance_never_mutates_authoritative_size_policy(self):
        self.assertNotIn("MacWSDockMaximumHeightByScene", WINDOWING)
        self.assertNotIn("MacWSDockSafeCenteredModelHeight", WINDOWING)
        self.assertNotIn("resize-response dock-constrained", WINDOWING)

    def test_native_dock_controller_yields_when_translation_cannot_fit(self):
        resolver = body(WINDOWING, "static id MacWSResolveFloatingDockController(")
        self.assertIn('@"SBFloatingDockWindow"', resolver)
        self.assertIn('@"floatingDockRootViewController"', resolver)
        request = body(WINDOWING, "static BOOL MacWSRequestFloatingDockYield(")
        self.assertIn('@"isFloatingDockPresented"', request)
        self.assertIn('@"SBFloatingDockBehaviorAssertion"', request)
        self.assertIn(
            '@"initWithFloatingDockController:visibleProgress:animated:gesturePossible:atLevel:reason:withCompletion:"',
            request,
        )
        self.assertIn("activeLevel + 1", request)
        self.assertIn("route=native-behavior-assertion", request)
        # Runtime proved one-shot dismissal is immediately superseded by the
        # homescreen assertion. It remains only as a compatibility fallback.
        self.assertIn('@"dismissFloatingDockIfPresentedAnimated:completionHandler:"', request)
        self.assertIn("route=native-dismiss", request)

    def test_native_dock_assertion_has_balanced_lifecycle(self):
        request = body(WINDOWING, "static BOOL MacWSRequestFloatingDockYield(")
        self.assertNotIn(
            "if (MacWSDockYieldAssertionByScene[sceneIdentifier]) return YES",
            request,
        )
        self.assertIn("dockPresented", request)
        self.assertIn('assertion-lost-visible-dock-authority', request)
        release = body(WINDOWING, "static void MacWSReleaseFloatingDockYield(")
        self.assertIn("MacWSDockYieldReleaseInFlightScenes", release)
        self.assertIn("MacWSDockYieldReleaseAssertionByScene", release)
        self.assertIn("2.5 * NSEC_PER_SEC", release)
        self.assertIn('reason, @"timeout"', release)
        invalidate = release.index("objc_msgSend)(assertion, selector")
        self.assertIn("weakAssertion", release)
        self.assertIn('@"invalidateWithCompletion:"', release)
        self.assertIn('@"invalidate"', release)
        finish = body(
            WINDOWING,
            "static void MacWSFinishFloatingDockYieldRelease(",
        )
        self.assertIn("MacWSDockYieldReleaseAssertionByScene", finish)
        self.assertIn("if (!reassert)", finish)
        self.assertIn(
            "MacWSRequestFloatingDockYield(sceneIdentifier, CGRectZero)",
            finish,
        )
        helper = body(WINDOWING, "static CGRect MacWSHostFrameAvoidingFloatingDock(")
        self.assertIn("hasYieldAssertion", helper)
        self.assertIn("wantsYield", helper)
        self.assertIn("MacWSDockYieldGeometryByScene", helper)
        self.assertIn('@"screen_edge_padding"', helper)
        self.assertIn('@"screen_scale"', helper)
        self.assertIn('@"window-fits-dock-safe-region"', helper)
        self.assertIn('@"container-geometry-changed"', helper)
        self.assertIn("MacWSRequestFloatingDockYield(sceneIdentifier, frame)", helper)
        self.assertLess(
            helper.index('@"window-fits-dock-safe-region"'),
            helper.index("CGFloat safeBottom"),
        )
        current_stage = body(
            WINDOWING, "static void MacWSReleaseDockYieldsOutsideCurrentStage(",
        )
        self.assertIn('@"_currentMainAppLayout"', current_stage)
        self.assertIn('@"scene-left-current-stage"', current_stage)

    def test_fullscreen_workspace_releases_dock_assertion(self):
        self.assertIn(
            'MacWSReleaseFloatingDockYield(\n'
            '                requestedIdentifier, @"entered-fullscreen-workspace")',
            WINDOWING,
        )
        self.assertIn(
            'MacWSReleaseFloatingDockYield(\n'
            '            requestedIdentifier, @"entering-fullscreen-workspace")',
            WINDOWING,
        )

    def test_translation_adapts_gap_without_touching_or_resizing(self):
        helper = body(WINDOWING, "static CGRect MacWSHostFrameAvoidingFloatingDock(")
        self.assertIn("minimumDockGap = 8.0 / effectiveScale", helper)
        self.assertIn("availableDockGap", helper)
        self.assertIn("MIN(padding, MAX(minimumDockGap", helper)
        self.assertIn("dockTop - dockGap - frame.size.height", helper)
        self.assertIn("topBoundary", helper)
        self.assertNotIn("frame.size.height =", helper)


if __name__ == "__main__":
    unittest.main()
