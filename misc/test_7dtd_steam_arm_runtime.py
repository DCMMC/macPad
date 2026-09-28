#!/usr/bin/env python3
"""Source invariants for the exact Steam-to-arm64 7DTD launch contract."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
STEAM_SOURCE = ROOT / "libmachook/Compatibility/MacWSSteamProcess.m"
PREFLIGHT = ROOT / "layout/usr/macOS/bin/prepare_steam_runtime.sh"
APP_INPUT = ROOT / "libmachook/AppInputBridge.m"
KEY_PROBE = ROOT / "misc/host_key_probe.py"
CLEANUP = ROOT / "misc/cleanup_all.sh"


class SevenDaysToDieSteamRuntimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = STEAM_SOURCE.read_text()
        cls.preflight = PREFLIGHT.read_text()
        cls.app_input = APP_INPUT.read_text()
        cls.key_probe = KEY_PROBE.read_text()
        cls.cleanup = CLEANUP.read_text()

    def test_only_exact_depot_entry_points_redirect_to_arm_runtime(self):
        body = self.source.split(
            "static NSURL *MacWSSteamRuntimeApplicationURL", 1
        )[1].split(
            "static bool MacWSIsSevenDaysToDieARMRuntimeExecutable", 1
        )[0]
        self.assertIn('isEqualToString:@"7 Days To Die/7dLauncher.app"', body)
        self.assertIn('isEqualToString:@"7 Days To Die/7DaysToDie.app"', body)
        self.assertIn(
            'relative = @"7 Days To Die/7DaysToDie-ARM.app";', body
        )
        self.assertIn('fileExistsAtPath:readyMarker', body)
        self.assertIn('fileExistsAtPath:infoPath', body)

    def test_arm_environment_is_exact_bundle_scoped(self):
        predicate = self.source.split(
            "static bool MacWSIsSevenDaysToDieARMRuntimeExecutable", 1
        )[1].split("static NSString *MacWSInsertLibraryForSteamExecutable", 1)[0]
        self.assertIn('isEqualToString:@"7 Days To Die"', predicate)
        self.assertIn(
            '"/steamapps/macws-runtime/7 Days To Die/"', predicate
        )
        self.assertIn('"7DaysToDie-ARM.app/Contents/MacOS/"', predicate)

        environment = self.source.split(
            "if (MacWSIsSevenDaysToDieARMRuntimeExecutable(executablePath))", 1
        )[1].split("// Stray's macOS 13 AGX", 1)[0]
        for key in (
            "MACWS_MONO_JIT_COMPAT",
            "MACWS_JIT_MPROTECT_COMPAT",
            "MACWS_JIT_FAULT_WRITE_COMPAT",
            "MACWS_CATALYST_DIRECT_DRAWABLE",
            "MACWS_AGX_OPCODE_ZERO_COMPAT",
            "MACWS_7DTD_RENDER_SCALE_COMPAT",
            "MACWS_SYNTHETIC_MOBILE_USER",
        ):
            self.assertIn(f'merged[@"{key}"] = @"1";', environment)
        self.assertIn('merged[@"MACWS_STRAY_TARGET_FPS"] = @"60";', environment)
        self.assertNotIn("MACWS_AGX_CRASH_DIAG", environment)
        self.assertNotIn("MACWS_JIT_MPROTECT_TRACE", environment)

    def test_second_steam_generation_reuses_checked_in_arm_runtime(self):
        helper = self.source.split(
            "static id MacWSExistingSevenDaysRuntimeApplication", 1
        )[1].split("static NSString *MacWSInsertLibraryForSteamExecutable", 1)[0]
        self.assertIn(
            "MacWSIsSevenDaysToDieARMRuntimeExecutable(executablePath)",
            helper,
        )
        self.assertIn("runningApplicationsWithBundleIdentifier:", helper)
        self.assertIn("isTerminated", helper)
        self.assertIn("executableURL", helper)
        self.assertIn("kill(processIdentifier, 0)", helper)

        launch = self.source.split(
            "static id MacWSSteamLaunchApplicationAtURL", 1
        )[1].split("static id MacWSSteamOpenURL", 1)[0]
        reuse = launch.index("MacWSExistingSevenDaysRuntimeApplication(")
        runtime_launch = launch.index(
            "gMacWSOriginalNSWorkspaceLaunchApplication(\n"
            "                workspace, selector, runtimeApplicationURL"
        )
        self.assertLess(reuse, runtime_launch)
        self.assertIn("existing 7DTD runtime reused", launch)

    def test_preflight_requires_real_arm64_runtime_and_resolved_resources(self):
        body = self.preflight.split("prepare_7dtd_arm_runtime()", 1)[1].split(
            "retire_breakpad_backlog()", 1
        )[0]
        self.assertIn('lipo "$source_executable" -verify_arch arm64', body)
        self.assertIn('7DaysToDie-ARM.app', body)
        self.assertIn('7DaysToDie.app', body)
        self.assertIn('[ -e "$destination/Data" ]', body)
        self.assertIn('[ -e "$destination/Contents/Resources" ]', body)
        self.assertIn('7dtd-arm64-unity-2022.3.62f2-v1', body)

    def test_preflight_runs_before_steam_trust_and_exec(self):
        prepare = self.preflight.index("prepare_7dtd_arm_runtime || exit $?")
        user_data = self.preflight.index("prepare_7dtd_user_data || exit $?")
        graphics = self.preflight.index(
            "prepare_7dtd_m2_graphics_profile || exit $?"
        )
        user_cache = self.preflight.index("prepare_steam_user_cache || exit $?")
        trust = self.preflight.index('/var/jb/usr/bin/bash "$TRUST_PREFLIGHT"')
        launch = self.preflight.index('exec "$CHROOT_EXEC"')
        self.assertLess(prepare, trust)
        self.assertLess(prepare, user_data)
        self.assertLess(user_data, graphics)
        self.assertLess(graphics, user_cache)
        self.assertLess(user_cache, trust)
        self.assertLess(trust, launch)

    def test_recovery_kills_the_exact_prepared_arm_player(self):
        self.assertIn(
            "seven_days_exec='/Users/root/Library/Application Support/Steam/"
            "steamapps/macws-runtime/7 Days To Die/7DaysToDie-ARM.app/"
            "Contents/MacOS/7 Days To Die'",
            self.cleanup,
        )
        self.assertIn('"$seven_days_exec"|"$seven_days_exec "*', self.cleanup)

    def test_preflight_repairs_only_exact_7dtd_data_roots(self):
        body = self.preflight.split("prepare_7dtd_user_data()", 1)[1].split(
            "retire_breakpad_backlog()", 1
        )[0]
        self.assertIn('local legacy="$support/7DaysToDie"', body)
        self.assertIn(
            'local unity="$support/com.The-Fun-Pimps.7-Days-To-Die"', body
        )
        self.assertIn('if [ -L "$directory" ]', body)
        self.assertIn('chown -R -h 501:501 "$directory"', body)
        self.assertNotIn('chown -R -h 501:501 "$support"', body)
        self.assertIn('local unity_logs="$logs/Unity"', body)
        self.assertIn('local mobile_preferences=', body)
        self.assertIn('cp -p "$root_preferences" "$mobile_game_preferences"', body)

    def test_m2_graphics_profile_uses_real_game_preferences_once(self):
        body = self.preflight.split(
            "prepare_7dtd_m2_graphics_profile()", 1
        )[1].split("prepare_steam_user_cache()", 1)[0]
        self.assertIn('[ "$machine" = iPad14,5 ] || return 0', body)
        self.assertIn("machine=$(sysctl -n hw.machine", body)
        self.assertNotIn("machine=$(/usr/sbin/sysctl", body)
        self.assertNotIn("iPad13,", body)
        defaults_helper = self.preflight.split(
            "run_7dtd_mobile_defaults()", 1
        )[1].split("prepare_7dtd_m2_graphics_profile()", 1)[0]
        self.assertIn("MACWS_CFPREFERENCES_CLIENT=1", defaults_helper)
        self.assertIn("MACWS_SYNTHETIC_MOBILE_USER=1", defaults_helper)
        self.assertIn("OptionsGfxUpscalerMode -int 4", body)
        self.assertIn("OptionsGfxDynamicScale -float 0.35", body)
        self.assertIn("MacWSM2GraphicsProfileVersion", body)
        self.assertIn("preserved user 7DTD dynamic scale", body)

    def test_preflight_repairs_only_the_exact_steam_cache_subtree(self):
        body = self.preflight.split("prepare_steam_user_cache()", 1)[1].split(
            "retire_breakpad_backlog()", 1
        )[0]
        self.assertIn('local steam_cache="$cache_root/Steam"', body)
        self.assertIn('chown -R -h 501:501 "$steam_cache"', body)
        self.assertNotIn('chown -R -h 501:501 "$cache_root"', body)

    def test_unity_input_uses_the_real_appkit_event_queue(self):
        predicate = self.app_input.split(
            "static BOOL MacWSMainBundleUsesQueuedGameInput", 1
        )[1].split("static void MacWSTrackOrderedWindow", 1)[0]
        self.assertIn("com.annapurnainteractive.Stray", predicate)
        self.assertIn("com.The-Fun-Pimps.7-Days-To-Die", predicate)
        self.assertIn("MacWSMainBundleIsSevenDaysToDie", self.app_input)
        self.assertIn("APP-INPUT UNITY-DID-SEND", self.app_input)
        self.assertIn("MacWSOriginalUnityDidSendEvent(self, command, event)",
                      self.app_input)
        key_route = self.app_input.split(
            "BOOL queueForGameTick = MacWSMainBundleUsesQueuedGameInput", 1
        )[1].split("CGFloat normalizedX", 1)[0]
        self.assertIn("queueForGameTick, NO", key_route)

    def test_native_player_publishes_fullscreen_drawable_capability(self):
        predicate = self.app_input.split(
            "static BOOL MacWSMainBundleUsesFullscreenCanvasPresentation", 1
        )[1].split("static NSSet *MacWSVisibleWindowNumberSnapshot", 1)[0]
        self.assertIn("com.annapurnainteractive.Stray", predicate)
        self.assertIn("com.The-Fun-Pimps.7-Days-To-Die", predicate)

    def test_modifier_poll_uses_current_event_only_at_exact_unity_callsite(self):
        compatibility = self.app_input.split(
            "static uint64_t MacWSSevenDaysCGEventSourceFlagsState", 1
        )[1].split("static void MacWSInstallUnityDidSendEventDiagnostic", 1)[0]
        self.assertIn("stateID == 1", compatibility)
        self.assertIn("MacWSAppInputDispatchModifierDepth != 0", compatibility)
        self.assertIn("0xf1de34u", compatibility)
        self.assertIn("return MacWSAppInputDispatchModifierFlags", compatibility)
        self.assertIn(
            "MacWSOriginalCGEventSourceFlagsState(stateID)", compatibility
        )
        self.assertIn(
            "D50F7C77-F422-3DE2-986B-1237215E50F7", compatibility
        )
        self.assertIn("expectedCallSite", compatibility)

        dispatch = self.app_input.split(
            "static void MacWSAppInputApplicationSendEvent", 1
        )[1].split("static void MacWSInstallApplicationKeyWitness", 1)[0]
        install = dispatch.index(
            "MacWSInstallSevenDaysModifierStateCompatibility()"
        )
        send = dispatch.index("MacWSOriginalApplicationSendEvent(")
        self.assertLess(install, send)
        self.assertIn('sel_registerName("modifierFlags")', dispatch)
        self.assertIn(
            "MacWSAppInputDispatchModifierFlags = "
            "previousDispatchModifierFlags",
            dispatch,
        )
        self.assertIn(
            "MacWSAppInputDispatchModifierDepth = "
            "previousDispatchModifierDepth",
            dispatch,
        )

    def test_key_probe_can_opt_in_to_correlated_latency_diagnostics(self):
        self.assertIn("LATENCY_DIAGNOSTIC", self.key_probe)
        self.assertIn('"--latency-diagnostic"', self.key_probe)
        self.assertIn("if args.latency_diagnostic else 0", self.key_probe)
        self.assertIn("APP-INPUT KEY-EVENT", self.app_input)
        self.assertIn("APP-INPUT KEY-RETURN", self.app_input)
        self.assertIn("APP-INPUT UNITY-DID-SEND", self.app_input)
        self.assertIn("APP-INPUT 7DTD-WORLD-STATE", self.app_input)

    def test_vnc_window_target_keeps_desktop_coordinate_affine(self):
        mapping = self.app_input.split(
            "BOOL exactSystemContinuation =", 1
        )[1].split("// A menu, sheet, tooltip", 1)[0]
        self.assertIn("record.source == MacWSInputSourceVNC", mapping)
        self.assertIn("inputMappingFrame = screenFrame", mapping)
        self.assertIn("normalizedX * screenFrame.size.width", mapping)
        self.assertIn("normalizedY) * screenFrame.size.height", mapping)

    def test_process_local_pointer_position_survives_unity_input_tick(self):
        poll = self.app_input.split(
            "static CGPoint MacWSAppInputCurrentMouseLocation", 1
        )[1].split("static void MacWSSendMouseEventWithStateBridge", 1)[0]
        self.assertIn("MacWSAppInputPersistentMouseLocationValid", poll)
        self.assertIn("MacWSAppInputPersistentMouseLocation", poll)
        local_route = self.app_input.split(
            "0xf2abac invokes +[NSEvent mouseLocation]", 1
        )[1].split("NSUInteger eventType", 1)[0]
        self.assertIn(
            "MacWSAppInputPersistentMouseLocation = screenPoint", local_route
        )
        self.assertIn(
            "MacWSAppInputPersistentMouseLocationValid = YES", local_route
        )
        dispatch = self.app_input.split(
            "Commit the location carried by every mouse NSEvent", 1
        )[1].split("if (MacWSOriginalApplicationSendEvent)", 1)[0]
        self.assertIn('sel_registerName("locationInWindow")', dispatch)
        self.assertIn('sel_registerName("convertPointToScreen:")', dispatch)
        self.assertIn(
            "MacWSAppInputPersistentMouseLocation = deliveredMouseLocation",
            dispatch,
        )

    def test_atomic_tap_uses_unitys_proven_split_gesture_path(self):
        adapter = self.app_input.split(
            "if (record.kind == MacWSInputKindTap &&", 1
        )[1].split("if (record.kind == MacWSInputKindOpenDocuments)", 1)[0]
        self.assertIn("MacWSMainBundleIsSevenDaysToDie()", adapter)
        self.assertIn("downRecord.kind = MacWSInputKindTouchDown", adapter)
        self.assertIn("upRecord.kind = MacWSInputKindTouchUp", adapter)
        self.assertEqual(adapter.count("MacWSEnqueueAppInputRecord("), 2)
        self.assertIn("50 * NSEC_PER_MSEC", adapter)
        self.assertIn("dispatch_after(dispatch_time(DISPATCH_TIME_NOW", adapter)
        generic = self.app_input.split(
            "if (record.kind == MacWSInputKindTap ||", 1
        )[1].split("if (usesBufferedTracking && record.kind", 1)[0]
        self.assertIn("MacWSCompletePrequeuedAtomicUp", generic)


if __name__ == "__main__":
    unittest.main()
