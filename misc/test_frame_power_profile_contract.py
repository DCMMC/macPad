import importlib.util
from pathlib import Path
import shlex
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "misc" / "macws_frame_power_profile.py"
SPEC = importlib.util.spec_from_file_location("macws_frame_power_profile",
                                              MODULE_PATH)
PROFILE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROFILE)
COMPARE_PATH = ROOT / "misc" / "macws_compare_profiles.py"
COMPARE_SPEC = importlib.util.spec_from_file_location("macws_compare_profiles",
                                                      COMPARE_PATH)
COMPARE = importlib.util.module_from_spec(COMPARE_SPEC)
COMPARE_SPEC.loader.exec_module(COMPARE)


class FramePowerProfileContract(unittest.TestCase):
    def test_cleanup_command_is_argv_only_and_reports_failure(self):
        success = PROFILE.run_cleanup_command(
            f"{shlex.quote(sys.executable)} -c " +
            shlex.quote("print('closed')"))
        self.assertEqual(success["returncode"], 0)
        self.assertEqual(success["stdout"].strip(), "closed")
        failure = PROFILE.run_cleanup_command(
            "/definitely/missing/macws-cleanup-command")
        self.assertIsNone(failure["returncode"])
        self.assertIn("error", failure)

    def test_process_cpu_summary_uses_cumulative_time_and_target_tree(self):
        before = {
            "captured_wall_time": 10.0,
            "processes": [
                {"pid": 20, "ppid": 1, "name": "MacWSHost",
                 "cpu_time_seconds": 2.0},
                {"pid": 30, "ppid": 1, "name": "Electron",
                 "cpu_time_seconds": 3.0},
                {"pid": 31, "ppid": 30, "name": "Code Helper",
                 "cpu_time_seconds": 4.0},
            ],
        }
        after = {
            "captured_wall_time": 20.0,
            "processes": [
                {"pid": 20, "ppid": 1, "name": "MacWSHost",
                 "cpu_time_seconds": 2.5},
                {"pid": 30, "ppid": 1, "name": "Electron",
                 "cpu_time_seconds": 3.2},
                {"pid": 31, "ppid": 30, "name": "Code Helper",
                 "cpu_time_seconds": 9.8},
            ],
        }
        result = PROFILE.process_cpu_summary(before, after, 30)
        self.assertAlmostEqual(
            result["roles"]["target_tree"]["average_cpu_percent"], 60.0)
        self.assertAlmostEqual(
            result["roles"]["macws_host"]["average_cpu_percent"], 5.0)
        self.assertTrue(next(item for item in result["processes"]
                        if item["pid"] == 31)["target_descendant"])

    def test_parse_cpu_time_supports_minutes_hours_and_days(self):
        self.assertEqual(PROFILE.parse_cpu_time("7:37.36"), 457.36)
        self.assertEqual(PROFILE.parse_cpu_time("2:03:04.50"), 7384.5)
        self.assertEqual(PROFILE.parse_cpu_time("1-02:03:04.50"), 93784.5)

    def test_process_snapshot_includes_arbitrary_target_and_descendants(self):
        class RemoteFixture:
            def run(self, *_args, **_kwargs):
                return """\
 10 1 0.0 0:01.00 100 200 /Applications/Terminal.app/Contents/MacOS/Terminal
 11 10 0.0 0:00.50 100 200 /usr/bin/login
 12 11 0.0 0:00.25 100 200 /bin/bash
 20 1 0.0 0:02.00 100 200 /usr/bin/unrelated
"""

        snapshot = PROFILE.process_snapshot(
            RemoteFixture(), footprint=False, target_pid=10)
        self.assertEqual(
            {item["pid"] for item in snapshot["processes"]}, {10, 11, 12})

    def test_powermetrics_parser_keeps_cpu_gpu_and_combined_power(self):
        fixture = """
*** Sampled system activity (fixture) ***
E-Cluster HW active residency:  30.00%
P-Cluster HW active residency:   4.00%
CPU Power: 100 mW
GPU Power: 25 mW
Combined Power (CPU + GPU + ANE): 126 mW
Current pressure level: Nominal
GPU active frequency: 528 MHz
GPU active residency:  20.00%
GPU requested frequency: (396 MHz: 80% 528 MHz: 20%)
GPU Power: 25 mW
*** Sampled system activity (fixture 2) ***
E-Cluster HW active residency:  40.00%
P-Cluster HW active residency:   6.00%
CPU Power: 200 mW
GPU Power: 75 mW
Combined Power (CPU + GPU + ANE): 276 mW
Current pressure level: Nominal
GPU active frequency: 720 MHz
GPU active residency:  50.00%
GPU requested frequency: (528 MHz: 50% 720 MHz: 50%)
GPU Power: 75 mW
"""
        samples = PROFILE.parse_powermetrics(fixture)
        self.assertEqual(len(samples), 2)
        summary = PROFILE.summarize_power(samples)
        self.assertEqual(summary["cpu_power_mw"]["mean"], 150.0)
        self.assertEqual(summary["gpu_power_mw"]["mean"], 50.0)
        self.assertEqual(summary["combined_power_mw"]["mean"], 201.0)
        self.assertEqual(summary["gpu_active_residency_percent"]["mean"],
                         35.0)

    def test_efficiency_uses_unique_visible_frames(self):
        power = {"combined_power_mw": {"mean": 2500.0}}
        cadence = {"unique_visible_frames": 300}
        result = PROFILE.efficiency_summary(power, cadence, 10.0)
        self.assertEqual(result["estimated_interval_energy_mj"], 25000.0)
        self.assertIsNone(result["steady_state_energy_per_visible_frame_mj"])
        cadence["average_fps"] = 100.0
        result = PROFILE.efficiency_summary(power, cadence, 10.0)
        self.assertEqual(
            result["steady_state_energy_per_visible_frame_mj"], 25.0)

    def test_dynamic_panel_budget_drives_host_hitch_accounting(self):
        source = (ROOT / "MacWSHost" / "MacWSPerformanceMonitor.m").read_text()
        self.assertIn("UIScreen.mainScreen.maximumFramesPerSecond", source)
        self.assertIn("1000.0 / _targetFramesPerSecond", source)
        self.assertIn("strongSelf->_targetFrameMilliseconds * 1.5", source)
        self.assertIn('@"display_maximum_fps": @(_targetFramesPerSecond)',
                      source)
        self.assertNotIn("MacWSPerfTargetFrameMilliseconds", source)

    def test_direct_drawable_pipeline_has_exact_sequence_latency_stages(self):
        source = (ROOT / "MacWSHost" /
                  "MacWSPerformanceMonitor.m").read_text()
        for witness in (
            "pendingReceiptSequences",
            "pendingReceiptTimes",
            "receiptToSubmission",
            "completionToSubmission",
            "submissionToVisible",
            "completionToVisible",
            '@"host_receipt_to_submission"',
            '@"producer_completion_to_visible_callback"',
        ):
            self.assertIn(witness, source)

    def test_profiler_does_not_poll_footprint_inside_interval(self):
        source = MODULE_PATH.read_text()
        measured = source.split(
            "cadence_process = start_cadence_stream", 1)[1].split(
            "process_after = process_snapshot", 1)[0]
        self.assertNotIn("footprint", measured)
        self.assertIn("process_before = process_snapshot", source)
        self.assertIn("process_after = process_snapshot", source)

    def test_cadence_summary_derives_authority_matched_producer_fps(self):
        samples = [
            {"activity": {"magic": PROFILE.ACTIVITY_MAGIC,
                           "timestamp_ns": 1_000_000_000,
                           "target_pace_us": 8333,
                           "producer_pid": 42,
                           "present_sequence": 100},
             "authority": {}},
            {"activity": {"magic": PROFILE.ACTIVITY_MAGIC,
                           "timestamp_ns": 1_250_000_000,
                           "target_pace_us": 8333,
                           "producer_pid": 42,
                           "present_sequence": 130},
             "authority": {}},
        ]
        summary = PROFILE.cadence_summary(samples)
        self.assertEqual(summary["producer_present_fps"]["mean"], 120.0)
        self.assertEqual(summary["producer_present_sequence"],
                         {"first": 100, "last": 130})

    def test_scheduler_summary_exposes_empty_ticks_and_frame_retention(self):
        summary = PROFILE.scheduler_summary({
            "elapsed_s": 10.0,
            "target": {"display_maximum_fps": 120},
            "counters": {
                "direct_drawable_scheduler_ticks": 1200,
                "direct_drawable_scheduler_empty_ticks": 20,
            },
            "direct_drawable": {"target": {
                "producer_delivered_average_fps": 118.0,
                "host_visible_average_fps": 117.8,
                "unique_frames_received": 1180,
                "host_unique_frames_presented": 1178,
            }},
        })
        self.assertEqual(summary["scheduler_tick_hz"], 120.0)
        self.assertEqual(summary["scheduler_empty_tick_hz"], 2.0)
        self.assertAlmostEqual(summary["scheduler_empty_percent"],
                               100.0 / 60.0)
        self.assertAlmostEqual(summary["delivery_retention_percent"],
                               1178 / 1180 * 100.0)

    def test_comparison_requires_fps_and_energy_efficiency(self):
        def report(label, fps, energy):
            return {
                "label": label,
                "cadence": {"average_fps": fps,
                            "one_percent_low_fps": fps * 0.75},
                "power": {"combined_power_mw": {"mean": 1000.0}},
                "efficiency": {
                    "steady_state_energy_per_visible_frame_mj": energy},
                "acceptance_inputs": {"command_errors": 0},
                "thermal_after": {"state": "nominal"},
                "screenshot": {"bytes": 100},
            }
        result = COMPARE.compare(
            report("before", 60.0, 20.0),
            report("after", 120.0, 10.0), 50.0, 5.0)
        self.assertEqual(result["result"], "PASS")
        self.assertEqual(result["changes"]["average_fps"]["percent"], 100.0)

    def test_comparison_exposes_direct_pipeline_latency_and_retention(self):
        def report(received, presented, receipt_p95):
            return {
                "cadence": {"average_fps": 120.0,
                            "one_percent_low_fps": 60.0},
                "power": {"combined_power_mw": {"mean": 1500.0}},
                "efficiency": {
                    "steady_state_energy_per_visible_frame_mj": 12.5},
                "host_profile": {
                    "direct_drawable": {"target": {
                        "producer_delivered_average_fps": 120.0,
                        "unique_frames_received": received,
                        "host_unique_frames_presented": presented,
                        "host_receipt_to_submission": {
                            "mean_ms": receipt_p95 / 2,
                            "p50_ms": receipt_p95 / 3,
                            "p95_ms": receipt_p95,
                            "p99_ms": receipt_p95 * 1.1,
                            "maximum_ms": receipt_p95 * 1.2,
                        },
                    }},
                    "counters": {
                        "direct_drawable_scheduler_ticks": 120,
                        "direct_drawable_scheduler_empty_ticks": 4,
                    },
                },
                "process_cpu": {"roles": {
                    "target_tree": {"average_cpu_percent": 90.0},
                    "macws_host": {"average_cpu_percent": 8.0},
                }},
                "acceptance_inputs": {"command_errors": 0},
                "thermal_after": {"state": "nominal"},
                "screenshot": {"bytes": 100},
            }
        result = COMPARE.compare(
            report(100, 95, 12.0), report(100, 99, 8.0), 0.0, 5.0)
        changes = result["changes"]
        self.assertEqual(changes["delivery_retention_percent"]["before"],
                         95.0)
        self.assertEqual(changes["delivery_retention_percent"]["after"],
                         99.0)
        self.assertAlmostEqual(
            changes["direct_pipeline_latency"]
                ["host_receipt_to_submission"]["p95_ms"]["delta"],
            -4.0)
        self.assertEqual(changes["direct_scheduler_counters"]
            ["direct_drawable_scheduler_ticks"]["after"], 120)
        self.assertEqual(changes["process_cpu"]["target_tree"]["after"],
                         90.0)


if __name__ == "__main__":
    unittest.main()
