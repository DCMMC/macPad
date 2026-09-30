"""Compare two macws_frame_power_profile.py reports with explicit gates."""

import argparse
import json
import pathlib


SCHEMA = "macws-frame-power-comparison-v1"


def change(before, after):
    if not isinstance(before, (int, float)) or not isinstance(after, (int, float)):
        return {"before": before, "after": after, "delta": None,
                "percent": None}
    delta = after - before
    percent = delta / before * 100.0 if before else None
    return {"before": before, "after": after, "delta": delta,
            "percent": percent}


def value(report, *keys):
    current = report
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def direct_target(report):
    target = value(report, "host_profile", "direct_drawable", "target")
    return target if isinstance(target, dict) else {}


def distribution_changes(baseline, candidate, key):
    before = direct_target(baseline).get(key, {})
    after = direct_target(candidate).get(key, {})
    return {
        statistic: change(before.get(statistic), after.get(statistic))
        for statistic in ("mean_ms", "p50_ms", "p95_ms", "p99_ms",
                          "maximum_ms")
    }


def delivery_retention(report):
    target = direct_target(report)
    received = target.get("unique_frames_received")
    presented = target.get("host_unique_frames_presented")
    if not isinstance(received, (int, float)) or received <= 0:
        return None
    if not isinstance(presented, (int, float)):
        return None
    return presented / received * 100.0


def compare(baseline, candidate, minimum_fps_gain_percent,
            maximum_energy_regression_percent):
    fps = change(value(baseline, "cadence", "average_fps"),
                 value(candidate, "cadence", "average_fps"))
    low = change(value(baseline, "cadence", "one_percent_low_fps"),
                 value(candidate, "cadence", "one_percent_low_fps"))
    power = change(value(baseline, "power", "combined_power_mw", "mean"),
                   value(candidate, "power", "combined_power_mw", "mean"))
    energy = change(value(
        baseline, "efficiency", "steady_state_energy_per_visible_frame_mj"),
        value(candidate, "efficiency",
              "steady_state_energy_per_visible_frame_mj"))
    producer_fps = change(
        direct_target(baseline).get("producer_delivered_average_fps"),
        direct_target(candidate).get("producer_delivered_average_fps"))
    delivery_retention_percent = change(
        delivery_retention(baseline), delivery_retention(candidate))
    command_errors = value(candidate, "acceptance_inputs", "command_errors")
    thermal = value(candidate, "thermal_after", "state")
    screenshot = candidate.get("screenshot")
    checks = {
        "cadence_measured": isinstance(fps["after"], (int, float)) and
            fps["after"] > 0,
        "minimum_fps_gain": isinstance(fps["percent"], (int, float)) and
            fps["percent"] >= minimum_fps_gain_percent,
        "energy_per_frame_not_regressed":
            isinstance(energy["percent"], (int, float)) and
            energy["percent"] <= maximum_energy_regression_percent,
        "no_command_errors": command_errors == 0,
        "thermal_not_serious": thermal not in {"serious", "critical"},
        "visual_witness_retained": isinstance(screenshot, dict) and
            screenshot.get("bytes", 0) > 0,
    }
    return {
        "schema": SCHEMA,
        "result": "PASS" if all(checks.values()) else "FAIL",
        "checks": checks,
        "gates": {
            "minimum_fps_gain_percent": minimum_fps_gain_percent,
            "maximum_energy_per_frame_regression_percent":
                maximum_energy_regression_percent,
        },
        "changes": {
            "average_fps": fps,
            "one_percent_low_fps": low,
            "combined_power_mw": power,
            "energy_per_visible_frame_mj": energy,
            "producer_delivered_average_fps": producer_fps,
            "delivery_retention_percent": delivery_retention_percent,
            "direct_pipeline_latency": {
                key: distribution_changes(baseline, candidate, key)
                for key in (
                    "completion_to_host_receipt",
                    "host_receipt_to_submission",
                    "producer_completion_to_submission",
                    "submission_to_visible_callback",
                    "producer_completion_to_visible_callback",
                    "host_visible_frame_interval",
                )
            },
            "direct_scheduler_counters": {
                key: change(
                    value(baseline, "host_profile", "counters", key),
                    value(candidate, "host_profile", "counters", key))
                for key in (
                    "direct_drawable_scheduler_ticks",
                    "direct_drawable_scheduler_empty_ticks",
                )
            },
            "process_cpu": {
                role: change(
                    value(baseline, "process_cpu", "roles", role,
                          "average_cpu_percent"),
                    value(candidate, "process_cpu", "roles", role,
                          "average_cpu_percent"))
                for role in (
                    "target_tree", "macws_host", "window_server",
                    "displayd",
                )
            },
        },
        "baseline_label": baseline.get("label"),
        "candidate_label": candidate.get("label"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=pathlib.Path)
    parser.add_argument("candidate", type=pathlib.Path)
    parser.add_argument("--minimum-fps-gain-percent", type=float, default=0.0)
    parser.add_argument("--maximum-energy-regression-percent", type=float,
                        default=5.0)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    candidate = json.loads(args.candidate.read_text())
    for name, report in (("baseline", baseline), ("candidate", candidate)):
        if report.get("schema") != "macws-frame-power-profile-v1":
            parser.error(f"{name} has unsupported schema")
    result = compare(
        baseline, candidate, args.minimum_fps_gain_percent,
        args.maximum_energy_regression_percent)
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    print(encoded, end="")
    if result["result"] != "PASS":
        raise SystemExit(2)


if __name__ == "__main__":
    main()
