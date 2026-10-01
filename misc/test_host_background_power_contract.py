"""Static ownership checks for Host background wake sources."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOST = (ROOT / "MacWSHost" / "main.m").read_text()
INTEROP = (ROOT / "MacWSHost" / "MacWSInteropClient.m").read_text()
METAL_VIEW = (ROOT / "MacWSHost" / "Rendering" / "MacWSMetalView.m").read_text()
HOSTD = (ROOT / "macwshostd" / "main.m").read_text()
MACHOOK = (ROOT / "libmachook" / "mac_hooks.m").read_text()
METAL_HOOKS = (ROOT / "libmachook" / "Metal_hooks.x").read_text()
APP_INPUT = (ROOT / "libmachook" / "AppInputBridge.m").read_text()
WORKSPACECTL = (ROOT / "macwsworkspacectl" / "main.m").read_text()
GUI_SCRIPT = (ROOT / "layout" / "usr" / "macOS" / "bin" / "macos_gui.sh").read_text()


def body(source: str, signature: str, next_signature: str) -> str:
    # Objective-C private interfaces repeat method signatures near the top of
    # the translation unit; the implementation is the final occurrence.
    start = source.rindex(signature)
    end = source.index(next_signature, start + len(signature))
    return source[start:end]


def test_scene_background_stops_status_timer_and_stream() -> None:
    section = body(HOST, "- (void)suspendSceneStream", "- (void)resumeSceneStream")
    assert "[_statusTimer invalidate]" in section
    assert "_statusTimer = nil" in section
    assert "[_metalView suspendStream]" in section


def test_disconnected_scene_relinquishes_process_global_drawable_delivery() -> None:
    section = body(
        HOST,
        "- (void)sceneDidDisconnect:",
        "- (void)scene:(UIScene *)scene openURLContexts:",
    )
    assert "[controller suspendSceneStream]" in section
    assert section.index("[controller suspendSceneStream]") < section.index(
        "dispatch_after")
    assert "MacWSCloseMacWindowForSceneSession" in section


def test_scene_resume_restarts_status_timer_once() -> None:
    section = body(
        HOST,
        "- (void)resumeSceneStream",
        "- (void)requestWindowLifetimeReconciliation",
    )
    assert "if (!_statusTimer)" in section
    assert "scheduledTimerWithTimeInterval:3.0" in section


def test_background_scene_releases_full_resolution_drawable_pool() -> None:
    suspend = body(METAL_VIEW, "- (void)suspendStream", "- (uint32_t)currentFrameWidth")
    assert "_streamSuspended = YES" in suspend
    assert "self.drawableSize = CGSizeMake(1.0, 1.0)" in suspend
    configure = body(
        METAL_VIEW,
        "- (void)configureStreamMode:",
        "- (uint64_t)inputSceneIDWithModifiers:",
    )
    assert "_streamSuspended = NO" in configure


def test_visible_scene_uses_bounded_drawable_pool() -> None:
    assert "maximumDrawableCount = 2" in METAL_VIEW


def test_target_change_retires_old_direct_drawable_owners() -> None:
    setter = body(
        METAL_VIEW,
        "- (void)setTargetPID:",
        "- (void)noteValidatedFullscreenCanvasForPID:",
    )
    assert "_scheduledCatalystDrawableFrame = nil" in setter
    assert "[_catalystDrawableCompositor removeAllFrames]" in setter
    assert "_directDrawableContinuousPacing = NO" in setter
    assert "maximumDrawableCount = 2" in setter


def test_event_driven_view_can_present_at_panel_cadence_without_idle_draws() -> None:
    assert "self.enableSetNeedsDisplay = YES" in METAL_VIEW
    assert "self.paused = YES" in METAL_VIEW
    assert "UIScreen.mainScreen.maximumFramesPerSecond" in METAL_VIEW
    assert "self.preferredFramesPerSecond = MAX(" in METAL_VIEW


def test_fully_occluded_stage_manager_scene_releases_its_stream() -> None:
    section = body(
        HOST,
        "- (void)synchronizeSceneOcclusionWithReason:",
        "- (void)synchronizeMacWindowFocusWithReason:",
    )
    assert "MacWSReadEffectiveSceneLifecycle" in section
    assert "occluded || backgrounded" in section
    assert "[self suspendSceneStream]" in section
    assert "[self resumeSceneStream]" in section
    assert "applicationKey" not in section
    assert "runtime-confirmed scene-occlusion" in section


def test_plain_texture_pool_reaps_only_retain_count_proven_idle_entries() -> None:
    assert "MACWS-MEMORY-REAP pool=plain-texture" in METAL_HOOKS
    assert "const NSUInteger idleBudget = 64U * 1024U * 1024U" in METAL_HOOKS
    assert "current <= baseline" in METAL_HOOKS
    assert "now - lastTime >= minimumIdleAge" in METAL_HOOKS
    assert 'entry[@"last_time"]' in METAL_HOOKS
    assert "clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)" in METAL_HOOKS


def test_foreground_scene_respects_system_auto_lock() -> None:
    foreground = body(
        HOST,
        "- (void)sceneWillEnterForeground:",
        "- (void)sceneDidBecomeActive:",
    )
    active = body(
        HOST,
        "- (void)sceneDidBecomeActive:",
        "- (void)sceneDidEnterBackground:",
    )
    assert "idleTimerDisabled = YES" not in foreground
    assert "idleTimerDisabled = YES" not in active
    assert "idleTimerDisabled = NO" in foreground


def test_application_background_cancels_clipboard_poll_source() -> None:
    section = body(
        INTEROP,
        "- (void)applicationDidEnterBackground:",
        "- (void)applicationDidBecomeActive:",
    )
    assert "self.pasteboardPollTimer = nil" in section
    assert "dispatch_source_cancel(timer)" in section


def test_application_activation_recreates_clipboard_poll_source() -> None:
    section = body(
        INTEROP,
        "- (void)applicationDidBecomeActive:",
        "- (void)publishStatus:",
    )
    assert "[self startPasteboardPolling]" in section
    assert "[self localPasteboardChanged:notification]" in section


def test_lock_state_uses_springboard_authority_and_a_durable_marker() -> None:
    assert '"SBGetScreenLockStatus"' in HOSTD
    assert "typedef void (*MacWSScreenLockStatus)(mach_port_t, BOOL *, BOOL *)" in HOSTD
    assert '"com.apple.springboard.lockstate"' in HOSTD
    assert "SetWorkspaceSleepMarker(YES)" in HOSTD
    assert "SetWorkspaceSleepMarker(NO)" in HOSTD
    assert "MacWSWorkspaceSleep.plist" in HOSTD


def test_only_owned_app_roots_and_descendants_are_suspended() -> None:
    collect = body(
        HOSTD,
        "static NSArray<NSDictionary *> *CollectWorkspaceApplicationProcesses",
        "static void PersistSuspendedWorkspaceProcesses",
    )
    assert "applicationLabels" in collect
    assert "gApplicationSessions.allValues" in collect
    assert "AddWorkspaceProcessAndDescendants" in collect
    transition = body(
        HOSTD,
        "static void ApplyWorkspacePowerState",
        "static void EvaluateWorkspacePowerState",
    )
    assert "kill(pid, SIGSTOP)" in transition
    assert "RootExecutablePathForPID(pid)" in transition
    assert "isEqualToString:expectedPath" in transition
    assert "killall" not in transition


def test_windowserver_blocks_completions_until_the_wake_edge() -> None:
    wait = body(
        MACHOOK,
        "static void macws_coexist_wait_while_workspace_sleeping",
        "static uint32_t macws_coexist_wait_for_completion_slot",
    )
    assert "MACWS_WORKSPACE_SLEEP_MARKER" in wait
    assert "poll(&descriptor, 1, 1000)" in wait
    slot = body(
        MACHOOK,
        "static uint32_t macws_coexist_wait_for_completion_slot",
        "static IOReturn MacwsIOMobileFramebufferSwapEnd_new",
    )
    assert "macws_coexist_wait_while_workspace_sleeping(wake_fd)" in slot


def test_appkit_receives_workspace_sleep_and_wake_notifications() -> None:
    assert "MACWS_WORKSPACE_WILL_SLEEP_NOTIFY" in APP_INPUT
    assert "MACWS_WORKSPACE_DID_WAKE_NOTIFY" in APP_INPUT
    assert '@"NSWorkspaceWillSleepNotification"' in APP_INPUT
    assert '@"NSWorkspaceDidWakeNotification"' in APP_INPUT


def test_window_metrics_uses_fast_bootstrap_and_slow_recovery() -> None:
    schedule = body(
        APP_INPUT,
        "static void MacWSScheduleWindowMetricsPublish(void)",
        "static void MacWSInstallWindowGeometryObservers(void)",
    )
    assert "500 * NSEC_PER_MSEC" in schedule
    assert "5 * NSEC_PER_SEC" in schedule
    assert "initialPublishScheduled" in schedule


def test_airplay_retry_loop_uses_the_supported_settings_path() -> None:
    assert '"APSSettingsSetUseXPCHelper"' in WORKSPACECTL
    assert 'dlsym(image, "APSSettingsGetInt64")' in WORKSPACECTL
    assert 'dlsym(image, "APSSettingsSetInt64")' in WORKSPACECTL
    assert 'CFSTR("p2pSolo")' in WORKSPACECTL
    assert '"APSSettingsSetUseXPCHelper"' in MACHOOK
    assert "setUseXPCHelper(false)" in MACHOOK
    assert 'strstr(info.dli_fname, "/AirPlaySupport.framework/")' in MACHOOK
    assert "configure-airplay-power" in GUI_SCRIPT
    control_center_load = 'launchctl load "$CONTROL_CENTER_PLIST"'
    assert GUI_SCRIPT.index("configure-airplay-power") < \
        GUI_SCRIPT.index(control_center_load)


if __name__ == "__main__":
    tests = [
        function for name, function in sorted(globals().items())
        if name.startswith("test_") and callable(function)
    ]
    for test in tests:
        test()
    print(f"{len(tests)} host background-power contract tests passed")
