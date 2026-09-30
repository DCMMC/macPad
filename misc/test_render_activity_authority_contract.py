"""Source contracts for focus-authorized adaptive compositor pacing."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = (ROOT / "include" / "macws_host_protocol.h").read_text()
DISPLAYD = (ROOT / "macwsdisplayd" / "main.m").read_text()
METAL = (ROOT / "libmachook" / "Metal_hooks.x").read_text()
MACHOOK = (ROOT / "libmachook" / "mac_hooks.m").read_text()
DRAWABLE_PROTOCOL = (
    ROOT / "include" / "macws_catalyst_drawable_protocol.h"
).read_text()
DRAWABLE_RECEIVER = (
    ROOT / "MacWSHost" / "Transport" /
    "MacWSCatalystDrawableReceiver.m"
).read_text()
STREAM_CLIENT = (
    ROOT / "MacWSHost" / "MacWSStreamClient.m"
).read_text()


class RenderActivityAuthorityContract(unittest.TestCase):
    def test_wire_record_identifies_generic_presenting_process(self):
        self.assertIn("#define MACWS_RENDER_ACTIVITY_VERSION 3u", PROTOCOL)
        self.assertIn("uint64_t presentSequence;", PROTOCOL)
        self.assertIn("macws_render_activity_present_sequence", METAL)
        self.assertIn("int32_t producerPID;", PROTOCOL)
        self.assertIn("MacWSRenderAuthorityRecord", PROTOCOL)

    def test_displayd_authorizes_only_visible_focused_surface_layer(self):
        predicate = DISPLAYD.split(
            "static BOOL LayerCanAuthorizeFocusedRender(", 1
        )[1].split(
            "static BOOL LayerNeedsIndependentFinalCompositeCapture(", 1
        )[0]
        for token in (
            "MacWSStreamWindowFocused",
            "MacWSStreamWindowVisible",
            "MacWSStreamWindowOnScreen",
            "layer.latestSurface",
        ):
            self.assertIn(token, predicate)
        publisher = DISPLAYD.split(
            "static BOOL PublishFocusedRenderAuthorityIdentity(", 1
        )[1].split("static BOOL PublishFocusedRenderAuthority(", 1)[0]
        self.assertIn("MACWS_RENDER_AUTHORITY_PATH", publisher)
        self.assertIn("MonotonicNanoseconds()", publisher)

    def test_window_mode_base_publishes_same_focused_authority(self):
        client = DISPLAYD.split(
            "@interface MacWSDisplayClient : NSObject", 1
        )[1].split("@end", 1)[0]
        self.assertIn("catalogFrontmostOwnerPID", client)
        self.assertIn("catalogFrontmostWindowID", client)

        frame = DISPLAYD.split(
            "static void PublishFrame(", 1
        )[1].split("static CGDisplayStreamRef CreateStream", 1)[0]
        for witness in (
            "client.mode == MacWSStreamModeWindow",
            "client.windowID == client.catalogFrontmostWindowID",
            "client.catalogFrontmostOwnerPID > 1",
            "PublishFocusedRenderAuthorityIdentity(",
        ):
            self.assertIn(witness, frame)

        catalog = DISPLAYD.split(
            "static void SendWindowList(", 1
        )[1].split("static void BroadcastWindowList", 1)[0]
        self.assertIn(
            "client.catalogFrontmostOwnerPID = frontmostPID", catalog
        )
        self.assertIn(
            "client.catalogFrontmostWindowID = frontmostWindowID", catalog
        )
        self.assertIn("client.lastSurfaceWidth", catalog)

        final_composite = DISPLAYD.split(
            "static void SuspendFullscreenLayerCapturesForFinalComposite", 2
        )[2].split(
            "static void ResumeFullscreenLayerCapturesForFallback", 1
        )[0]
        self.assertIn(
            "PublishFocusedWindowClientAuthorityIfAvailable()",
            final_composite,
        )
        self.assertLess(
            final_composite.index(
                "PublishFocusedWindowClientAuthorityIfAvailable()"
            ),
            final_composite.index("RetireFocusedRenderAuthority()"),
        )

    def test_focused_window_direct_suspends_redundant_capture_and_pacing(self):
        validator = DISPLAYD.split(
            "static BOOL ValidateDirectDrawableWindowBase(", 1
        )[1].split("static void ClearDirectDrawableActivity", 1)[0]
        for token in (
            "client.mode != MacWSStreamModeWindow",
            "client.windowID != layerWindowID",
            "client.catalogFrontmostWindowID != layerWindowID",
            "client.catalogFrontmostOwnerPID != ownerPID",
            "widthDifference * 5u > baseWidth",
            "heightDifference * 5u > baseHeight",
        ):
            self.assertIn(token, validator)
        self.assertIn("BOOL ownsBaseSuspension", validator)
        self.assertIn("(!client.stream && !ownsBaseSuspension)", validator)

        handler = DISPLAYD.split(
            "static void HandleDirectDrawableActivity(", 1
        )[1].split(
            "static void SuspendFullscreenLayerCapturesForFinalComposite", 1
        )[0]
        self.assertIn("ValidateDirectDrawableWindowBase(", handler)
        lease = handler.split(
            "client.directDrawableHeight = (uint32_t)heightValue;", 1
        )[1].split("ScheduleDirectDrawableExpiry(client);", 1)[0]
        self.assertIn("PublishDirectDrawablePacingLease(", lease)
        self.assertIn("directDrawablePacingLeasePublished = YES", lease)
        self.assertNotIn(
            "if (!windowBase)", lease,
            "an authenticated exact-window drawable must retire the "
            "redundant WindowServer 120-Hz completion loop too",
        )
        self.assertIn("directDrawableBaseCaptureSuspended = YES", handler)
        self.assertIn("[strongClient stopStream]", handler)

        clearer = DISPLAYD.split(
            "static void ClearDirectDrawableActivity(", 2
        )[2].split("static void ScheduleDirectDrawableExpiry", 1)[0]
        self.assertIn("resumeWindowBase", clearer)
        self.assertIn("StartClientStream(client)", clearer)

        subscription = DISPLAYD.split(
            "static void StartSubscription(", 1
        )[1].split("static void ConfigureNativePopupComposite", 1)[0]
        generic_subscription = subscription.split(
            "// The generic path replaces the client's entire capture graph",
            1,
        )[1]
        self.assertLess(
            generic_subscription.index("RetireDirectDrawablePacingLease()"),
            generic_subscription.index("client.subscriptionActive = YES"),
        )
        self.assertLess(
            generic_subscription.index("client.directDrawableActive = NO"),
            generic_subscription.index("StartClientStream(client)"),
        )

        sender = STREAM_CLIENT.split(
            "- (void)noteDirectDrawableForOwnerPID:", 1
        )[1].split("- (void)clearDirectDrawableActivity", 1)[0]
        self.assertIn("self.mode != MacWSStreamModeFullscreen", sender)
        self.assertIn("self.mode != MacWSStreamModeWindow", sender)

        view = (ROOT / "MacWSHost" / "Rendering" /
                "MacWSMetalView.m").read_text()
        draw = view.split("- (void)drawInMTKView:", 1)[1].split(
            "- (BOOL)resolveFullscreenLayerAtPoint:", 1
        )[0]
        self.assertIn("BOOL focusedWindowDirectAuthoritative", draw)
        self.assertIn("!focusedWindowDirectAuthoritative", draw)
        self.assertIn('fullscreenDirectAuthoritative ? @"fullscreen" : @"window"',
                      draw)
        direct_window_draw = draw.index(
            "if (directSurface && !finalComposite &&\n"
            "        !fullscreenDirectAuthoritative && baseCatalystFrame.texture)"
        )
        direct_window_encode = draw.index(
            "if (MacWSEncodeCatalystDrawable(", direct_window_draw
        )
        pipeline_bind = draw.index(
            "[encoder setRenderPipelineState:_pipeline];", direct_window_draw
        )
        self.assertLess(
            pipeline_bind,
            direct_window_encode,
            "base elision must not reach drawPrimitives without an explicit "
            "render pipeline binding",
        )

    def test_generic_producer_requires_authority_ancestry_and_size(self):
        validator = METAL.split(
            "static void macws_refresh_focused_render_authority(", 1
        )[1].split("static void macws_note_render_activity", 1)[0]
        self.assertIn("macws_process_descends_from(getpid(), record.ownerPID)",
                      validator)
        self.assertIn("widthDifference * 5u <= authorityWidth", validator)
        self.assertIn("heightDifference * 5u <= authorityHeight", validator)
        writer = METAL.split(
            "static void macws_publish_render_activity(", 1
        )[1].split("static void macws_note_render_activity(", 1)[0]
        self.assertIn(".producerPID = gameProducer ? 0 : getpid()", writer)
        self.assertIn("observedPaceUS", writer)

    def test_offscreen_present_cannot_consume_publish_throttle(self):
        note = METAL.split(
            "static void macws_note_render_activity(", 1
        )[1].split("static BOOL macws_stray_full_render_trace_enabled", 1)[0]
        authority = note.index(
            "macws_drawable_matches_focused_render_authority")
        publish = note.index("macws_publish_render_activity")
        self.assertLess(authority, publish)
        writer = METAL.split(
            "static void macws_publish_render_activity(", 1
        )[1].split("static void macws_note_render_activity(", 1)[0]
        self.assertLess(
            writer.index("macws_note_observed_present_interval"),
            writer.index("macws_stray_last_render_activity_ns"),
        )

    def test_active_cadence_discovers_120hz_then_adapts(self):
        estimator = METAL.split(
            "static uint32_t macws_note_observed_present_interval", 1
        )[1].split("static void macws_refresh_focused_render_authority", 1)[0]
        for witness in (
            "initialDiscoveryNS = 750 * NSEC_PER_MSEC",
            "rediscoveryPeriodNS = 5 * NSEC_PER_SEC",
            "return 8333",
            "macws_quantize_observed_present_pace",
        ):
            self.assertIn(witness, estimator)

    def test_generic_drawable_present_path_is_hooked_without_per_frame_lock(self):
        installer = METAL.split(
            "static void macws_install_stray_agx_present_trace", 1
        )[1].split("static void macws_install_stray_compute_execution_trace", 1)[0]
        self.assertIn("macws_install_stray_drawable_present_trace();",
                      installer)
        self.assertNotIn(
            "if (gameProcess) macws_install_stray_drawable_present_trace()",
            installer)
        class_installer = METAL.split(
            "static void macws_install_stray_drawable_class_trace", 1
        )[1].split("static id macws_stray_next_drawable_trace", 1)[0]
        self.assertLess(
            class_installer.index("g_macws_drawable_hooked_class_fast"),
            class_installer.index("pthread_mutex_lock"))

    def test_drawable_boundary_is_installed_before_device_creation(self):
        constructor = METAL.split(
            "__attribute__((constructor)) static void InitMetalHooks()", 1
        )[1]
        early_install = constructor.index(
            "macws_install_stray_drawable_present_trace();")
        plugin_hook = constructor.index(
            "%init(getMetalPluginClassForService")
        self.assertLess(early_install, plugin_hook)

    def test_chromium_layer_surface_boundary_preserves_setter_and_authority(self):
        wrapper = METAL.split(
            "static void macws_chromium_layer_set_contents_activity(", 1
        )[1].split(
            "static void macws_install_chromium_layer_contents_activity", 1
        )[0]
        self.assertLess(
            wrapper.index("g_macws_layer_set_contents_orig(layer, selector, contents)"),
            wrapper.index("macws_note_render_activity_dimensions"),
        )
        for token in (
            'strstr(contentsClass, "IOSurface")',
            "IOSurfaceGetWidth(surface)",
            "IOSurfaceGetHeight(surface)",
        ):
            self.assertIn(token, wrapper)
        detector = METAL.split(
            "static BOOL macws_is_chromium_gpu_process", 1
        )[1].split(
            "static void macws_chromium_layer_set_contents_activity", 1
        )[0]
        self.assertIn('strcmp(argument, "--type=gpu-process") == 0', detector)

    def test_focused_layer_direct_path_reuses_authorized_iosurface(self):
        wrapper = METAL.split(
            "static void macws_chromium_layer_set_contents_activity(", 1
        )[1].split(
            "static void macws_install_chromium_layer_contents_activity", 1
        )[0]
        self.assertLess(
            wrapper.index("g_macws_layer_set_contents_orig(layer, selector, contents)"),
            wrapper.index("macws_publish_completed_catalyst_drawable"),
        )
        for token in (
            "MACWS_FOCUSED_LAYER_DIRECT",
            "MacWSFocusedRenderAuthority authority = {0}",
            "int32_t authorityOwner = authority.ownerPID",
            "(IOSurfaceRef)CFRetain(surface)",
        ):
            self.assertIn(token, wrapper)
        self.assertIn("static BOOL directEnabled = YES", wrapper)
        self.assertIn('strcmp(value, "0") != 0', wrapper)
        self.assertNotIn(
            "macws_process_descends_from(getpid(), authorityOwner)", wrapper)

    def test_drawable_transport_reuses_copy_send_surface_ports(self):
        publisher = METAL.split(
            "static void macws_publish_completed_catalyst_drawable(", 1
        )[1].split("static void macws_record_stray_present", 1)[0]
        cache = METAL.split(
            "static mach_port_t macws_lock_cached_catalyst_surface_port(", 1
        )[1].split(
            "static void macws_unlock_cached_catalyst_surface_port", 1
        )[0]
        self.assertIn("macws_catalyst_surface_ports[3]", METAL)
        self.assertIn("IOSurfaceCreateMachPort(surface)", cache)
        self.assertIn("macws_lock_cached_catalyst_surface_port", publisher)
        self.assertIn("MACH_MSG_TYPE_COPY_SEND", publisher)
        self.assertNotIn(
            "mach_port_deallocate(mach_task_self(), surfacePort)", publisher)

    def test_direct_layer_and_desktop_are_fused_in_one_fragment_pass(self):
        host = (ROOT / "MacWSHost" / "Rendering" /
                "MacWSMetalView.m").read_text()
        wrapper = METAL.split(
            "static void macws_chromium_layer_set_contents_activity(", 1
        )[1].split(
            "static void macws_install_chromium_layer_contents_activity", 1
        )[0]
        self.assertIn("MacWSCatalystDrawableOpaque = 1u << 1",
                      DRAWABLE_PROTOCOL)
        self.assertIn("@selector(isOpaque)", wrapper)
        self.assertIn("MacWSCatalystDrawableOpaque : 0", wrapper)

        draw = host.split("- (void)drawInMTKView:", 1)[1].split(
            "- (BOOL)resolveFullscreenLayerAtPoint:", 1
        )[0]
        for witness in (
            "descriptor.layerWindowID ==",
            "_directDrawableHeartbeatLayerID",
            "setRenderPipelineState:_directCompositePipeline",
            "setFragmentTexture:baseCatalystFrame.texture",
            "fusedFocusedDirect = YES",
            "!fusedFocusedDirect",
        ):
            self.assertIn(witness, draw)
        self.assertLess(
            draw.index("setRenderPipelineState:_directCompositePipeline"),
            draw.index("BOOL encodedDirect = MacWSEncodeCatalystDrawable"),
        )
        shader = host.split('"fragment half4 macws_direct_composite', 1)[1]
        shader = shader.split('"fragment half4 macws_shadow', 1)[0]
        self.assertIn("if (foreground.a >= 0.999h) return foreground", shader)
        self.assertIn(
            "return foreground + background * (1.0h - foreground.a)",
            shader,
        )

    def test_host_and_displayd_revalidate_descendant_direct_surface(self):
        host = (ROOT / "MacWSHost" / "Rendering" /
                "MacWSMetalView.m").read_text()
        handler = host.split(
            "- (void)catalystDrawableDidPresent:", 1
        )[1].split(
            "- (NSString *)exportCatalystDrawableProbeForPID:", 1
        )[0]
        self.assertIn("direct.producerPID != direct.ownerPID", handler)
        self.assertIn("int32_t logicalOwnerPID = direct.ownerPID", handler)
        self.assertIn("strongSelf.targetPID == ownerPID", handler)
        self.assertIn("#define MACWS_CATALYST_DRAWABLE_VERSION 3u",
                      DRAWABLE_PROTOCOL)
        self.assertIn("int32_t producerPID;", DRAWABLE_PROTOCOL)
        self.assertIn("record.producerPID != senderPID", DRAWABLE_RECEIVER)
        validator = DISPLAYD.split(
            "static MacWSTransientLayer *ValidatedDirectDrawableLayer(", 1
        )[1].split("static void ClearDirectDrawableActivity", 1)[0]
        for token in (
            "MacWSStreamWindowFocused",
            "MacWSStreamWindowVisible",
            "MacWSStreamWindowOnScreen",
            'rejectionReason = @"focused-size"',
        ):
            self.assertIn(token, validator)

    def test_drawable_receiver_uses_bounded_two_message_catch_up(self):
        handler = DRAWABLE_RECEIVER.split(
            "dispatch_source_set_event_handler(DrawableSource, ^{", 1
        )[1].split("});\n        dispatch_resume(DrawableSource);", 1)[0]
        self.assertIn("messageBudget = 0; messageBudget < 2", handler)
        self.assertNotIn("for (;;)", handler)
        self.assertIn("mach_msg(", handler)
        self.assertIn("if (received == MACH_RCV_TIMED_OUT) break;", handler)
        self.assertIn("CFRelease(surface);", handler)

    def test_authenticated_focused_drawable_bypasses_60hz_uikit_coalescing(self):
        host = (ROOT / "MacWSHost" / "Rendering" /
                "MacWSMetalView.m").read_text()
        handler = host.split(
            "- (void)catalystDrawableDidPresent:", 1
        )[1].split(
            "- (NSString *)exportCatalystDrawableProbeForPID:", 1
        )[0]
        self.assertIn("focusedDirectUpdate = matchedWindowID != 0", handler)
        self.assertIn("logicalOwnerPID == self.targetPID", handler)
        self.assertIn("_lastDirectDrawableReceiptTime = CACurrentMediaTime()",
                      handler)
        self.assertIn("_directDrawableContinuousPacing = YES", handler)
        self.assertIn("self.enableSetNeedsDisplay = NO", handler)
        self.assertIn("maximumDrawableCount = 3", handler)
        self.assertIn(
            "MacWSConfigureMTKDisplayLinkForActiveAnimation(self)", handler
        )
        self.assertIn("self.paused = NO", handler)
        self.assertIn("[self setNeedsDisplay];", handler)
        self.assertNotIn("[self draw];", handler)
        self.assertNotIn("[self draw];", handler)

        presenter = host.split("- (void)drawInMTKView:", 1)[1].split(
            "BOOL drewCatalystDrawable", 1
        )[0]
        self.assertIn("if (_directDrawableContinuousPacing)", presenter)
        self.assertIn("dequeueFrameForOwnerPID:", presenter)
        self.assertIn("BOOL hasScheduledFrame", presenter)
        self.assertIn("_lastDirectDrawableReceiptTime", presenter)
        self.assertIn("idle >= 0.25", presenter)
        self.assertIn("recordDirectDrawableSchedulerTickWithFrame", presenter)
        self.assertIn("self.paused = YES", presenter)
        self.assertIn("self.enableSetNeedsDisplay = YES", presenter)
        self.assertIn("maximumDrawableCount = 2", presenter)

        scheduler = host.split(
            "static CADisplayLink *MacWSMTKDisplayLink", 1
        )[1].split("typedef NS_ENUM", 1)[0]
        self.assertIn('class_getInstanceVariable(MTKView.class,', scheduler)
        self.assertIn('"_displayLink"', scheduler)
        self.assertIn('NSSelectorFromString(@"setNominalFramesPerSecond:")',
                      scheduler)
        self.assertIn("targetFPS >= 120 ? 80.0f", scheduler)
        self.assertIn("CAFrameRateRangeMake(minimumFPS, targetFPS, targetFPS)",
                      scheduler)
        self.assertIn('NSSelectorFromString(@"setHighFrameRateReason:")',
                      scheduler)
        self.assertIn(
            "MACWS_CA_HIGH_FRAME_RATE_REASON_MAKE(0x4d57, 1)", host
        )
        self.assertIn("MacWSClearMTKDisplayLinkHighFrameRateReason(self)",
                      presenter)

        compositor = (ROOT / "MacWSHost" / "Rendering" /
                      "MacWSCatalystDrawableCompositor.m").read_text()
        self.assertIn("arrayWithCapacity:3", compositor)
        self.assertIn("while (pending.count > 3)", compositor)
        self.assertIn("dequeueFrameForOwnerPID:", compositor)

        receiver = (ROOT / "MacWSHost" / "Transport" /
                    "MacWSCatalystDrawableReceiver.m").read_text()
        self.assertIn(
            "messageBudget = 0; messageBudget < 2", receiver
        )
        self.assertNotIn("for (;;) {", receiver)

    def test_generic_agx_present_avoids_game_direct_drawable_path(self):
        wrapper = METAL.split(
            "static void macws_agx_present_drawable_trace(", 1
        )[1].split("static void macws_agx_present_drawable_at_time_trace", 1)[0]
        self.assertIn("macws_note_render_activity(drawable)", wrapper)
        self.assertIn("macws_catalyst_direct_drawable_enabled()", wrapper)

    def test_windowserver_revalidates_authority_before_active_pace(self):
        validator = MACHOOK.split(
            "static BOOL macws_render_activity_is_authorized(", 1
        )[1].split("static uint32_t macws_coexist_activity_pace_us", 1)[0]
        self.assertIn("authorityFreshnessNS", validator)
        self.assertIn("macws_process_descends_from_pid(activity->producerPID",
                      validator)
        consumer = MACHOOK.split(
            "static uint32_t macws_coexist_activity_pace_us", 1
        )[1].split("static int macws_coexist_interaction_wake_socket", 1)[0]
        self.assertIn("macws_render_activity_is_authorized(&record, now_ns)",
                      consumer)

    def test_static_desktop_retains_100ms_idle_pace(self):
        idle = MACHOOK.split(
            "static uint32_t macws_coexist_completion_pace_us", 1
        )[1].split("static BOOL macws_process_descends_from_pid", 1)[0]
        self.assertIn("kDefaultPaceUS = 100000", idle)


if __name__ == "__main__":
    unittest.main()
