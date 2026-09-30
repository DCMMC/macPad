"""Repeatable MacWS UI performance, input and stability profile.

Run this from the controlling Mac. The workload executes on the iPad against
one real AppKit InputLab window, while MacWSHost records actual drawable
presentation callbacks and the complete DisplayStream/Metal stage timings.
No MacBook baseline run is required; fixed release floors are embedded here.

The wire-level replayer deliberately complements rather than replaces a real
finger run: it validates every native event family and rendering response, but
cannot include UIKit recognizer latency before MacWSInputRecord is produced.
"""

import argparse
import json
import pathlib
import re
import shlex
import subprocess
import time


THRESHOLDS = {
    # Cadence floors are resolved from the measured panel maximum in each
    # MacWSHost profile.  A fixed 60-fps gate made a 120-Hz iPad report PASS
    # while missing every second refresh opportunity.
    "minimum_active_average_fraction": 0.90,
    "minimum_one_percent_low_fraction": 0.75,
    "maximum_input_bridge_p95_ms": 8.0,
    "maximum_input_to_visible_p95_ms": 50.0,
    "maximum_real_app_main_dispatch_p95_ms": 16.7,
    "maximum_real_app_click_complete_p95_ms": 50.0,
    "minimum_motion_60_delivery_hz": 45.0,
    "minimum_motion_120_delivery_hz": 60.0,
    "maximum_command_errors": 0,
    "minimum_visible_interval_samples": 30,
    "minimum_input_visible_samples": 12,
}


def cadence_thresholds(profile):
    target = profile.get("target", {}).get("display_maximum_fps")
    if not isinstance(target, (int, float)) or target <= 0:
        target = profile.get("target", {}).get("active_fps", 60.0)
    if not isinstance(target, (int, float)) or target <= 0:
        target = 60.0
    return {
        "target_fps": float(target),
        "minimum_active_average_fps": float(target) *
            THRESHOLDS["minimum_active_average_fraction"],
        "minimum_one_percent_low_fps": float(target) *
            THRESHOLDS["minimum_one_percent_low_fraction"],
    }


class Remote:
    def __init__(self, host, user, port):
        self.base = [
            "ssh", "-p", str(port), "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8", f"{user}@{host}",
        ]

    def run(self, command, *, timeout=45, check=True):
        result = subprocess.run(
            self.base + [command], capture_output=True, text=True,
            timeout=timeout,
        )
        if check and result.returncode:
            raise RuntimeError(
                f"remote command failed rc={result.returncode}: "
                f"{result.stderr.strip()}\ncommand={command}")
        return result.stdout


def parse_json(text, label):
    start = text.find("{")
    if start < 0:
        raise RuntimeError(f"{label} emitted no JSON: {text[-500:]}")
    return json.loads(text[start:])


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1,
                       int(len(ordered) * fraction + 0.999999) - 1))
    return ordered[index]


def summarize_real_app_input_latency(records):
    def summary(key):
        values = [float(item[key]) / 1000.0 for item in records
                  if key in item]
        return {
            "samples": len(values),
            "p50_ms": percentile(values, 0.50),
            "p95_ms": percentile(values, 0.95),
            "maximum_ms": max(values) if values else None,
        }
    completed = [
        (float(item["total_us"]) + float(item["dispatch_us"])) / 1000.0
        for item in records
        if "total_us" in item and "dispatch_us" in item
    ]
    return {
        "samples": len(records),
        "producer_to_main": summary("total_us"),
        "transport": summary("transport_us"),
        "main_queue": summary("queue_us"),
        "appkit_dispatch": summary("dispatch_us"),
        "producer_to_appkit_complete": {
            "samples": len(completed),
            "p50_ms": percentile(completed, 0.50),
            "p95_ms": percentile(completed, 0.95),
            "maximum_ms": max(completed) if completed else None,
        },
    }


def thermal_snapshot(remote):
    # The watchdog log is intentionally shared with recovery/status messages,
    # so its last line is not necessarily a thermal sample.  Query the same
    # low-frequency helper directly at each regression boundary; fall back to
    # the newest thermal-bearing watchdog line only if the helper is absent.
    raw = remote.run(
        "/var/jb/usr/macOS/bin/macwsthermal 2>&1 || true",
        check=False).strip()
    if not re.search(r"thermal-state=([a-z]+)", raw):
        raw = remote.run(
            "grep 'thermal-state=' "
            "/var/jb/var/mobile/macos_gui_watchdog.log 2>/dev/null | "
            "tail -n 1 || true", check=False).strip()
    state = re.search(r"thermal-state=([a-z]+)", raw)
    temperature = re.search(r"effective-temp-centic=(\d+)", raw)
    return {
        "state": state.group(1) if state else "unknown",
        "temperature_c": (int(temperature.group(1)) / 100.0
                          if temperature else None),
        "witness": raw,
    }


def process_snapshot(remote):
    names = [
        "WindowServer", "macwsdisplayd", "MacWSHost", "UIKitSystem",
        "MacWSInputLab", "Dock",
    ]
    output = remote.run("ps -axo pid=,comm=", timeout=15)
    result = {name: [] for name in names}
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        basename = pathlib.PurePosixPath(fields[1]).name
        if basename in result:
            result[basename].append(int(fields[0]))
    return result


def run_remote_python(remote, remote_repo, script, arguments,
                      *, timeout=45, expect_json=False):
    command = "cd {} && python3 {} {}".format(
        shlex.quote(str(pathlib.PurePosixPath(remote_repo) / "misc")),
        shlex.quote(script),
        " ".join(shlex.quote(str(value)) for value in arguments),
    )
    output = remote.run(command, timeout=timeout)
    return parse_json(output, script) if expect_json else output.strip()


def wait_for_profile(remote, previous_marker, timeout=8.0):
    path = "/var/mobile/Library/Logs/MacWSPerformance/latest.json"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        marker = remote.run(
            # Host commits latest.json with NSDataWritingAtomic.  Seconds and
            # byte size can legitimately repeat for adjacent gesture exports;
            # the atomic replacement's inode is the generation witness.
            f"stat -c '%Y:%s:%i' {path} 2>/dev/null || true",
            check=False).strip()
        if marker and marker != previous_marker:
            return marker, json.loads(remote.run(f"cat {path}"))
        time.sleep(0.15)
    raise RuntimeError("MacWSHost did not export a fresh performance JSON")


def execute_gesture_suite(remote, dock_pid, target_pid, requested=None):
    scenarios = [
        "tap", "tap-burst", "double-tap", "right-tap", "hover", "drag", "long-drag",
        "scroll", "scroll-momentum", "magnify",
    ]
    if dock_pid > 1:
        scenarios.extend((
            "three-up", "three-down", "three-left", "three-right",
            "mission-select",
        ))
    if requested:
        unknown = [name for name in requested if name not in scenarios]
        if unknown:
            raise RuntimeError(f"unknown/unavailable scenarios: {unknown}")
        scenarios = list(requested)
    results = []
    log_path = "/var/mobile/Library/Logs/MacWSHost.log"
    for name in scenarios:
        latest_path = "/var/mobile/Library/Logs/MacWSPerformance/latest.json"
        previous_marker = remote.run(
            f"stat -c '%Y:%s:%i' {latest_path} 2>/dev/null || true",
            check=False).strip()
        latency_path = ("/var/mnt/rootfs/private/tmp/"
                        f"macws_input_latency.{target_pid}.jsonl")
        latency_offset = int(remote.run(
            f"wc -c < {latency_path} 2>/dev/null || printf 0",
            check=False).strip() or 0)
        remote.run("uiopen --url macwshost://performance-reset")
        time.sleep(0.25)
        offset = int(remote.run(
            f"wc -c < {log_path} 2>/dev/null || printf 0").strip() or 0)
        started = time.monotonic()
        remote.run(f"uiopen --url macwshost://performance-gesture-{name}")
        deadline = time.monotonic() + 6.0
        log_delta = ""
        success = False
        while time.monotonic() < deadline:
            log_delta = remote.run(
                f"tail -c +{offset + 1} {log_path} 2>/dev/null || true",
                check=False)
            if re.search(
                    rf"performance-gesture-end scenario={re.escape(name)} "
                    r"success=YES", log_delta):
                success = True
                break
            if re.search(
                    rf"performance-url-gesture scenario={re.escape(name)} "
                    r"success=NO", log_delta):
                break
            time.sleep(0.1)
        results.append({
            "scenario": name,
            "result": "PASS" if success else "FAIL",
            "elapsed_s": time.monotonic() - started,
            "host_log": log_delta,
        })
        if not success:
            raise RuntimeError(f"Host gesture scenario failed: {name}")
        latency_records = []
        if name == "tap-burst":
            # CGPostMouseEvent enters the target application's real main-loop
            # tracker asynchronously. On Terminal a 24-click burst can finish
            # at the Host while the final AppKit completions are still
            # draining. Wait for the declared scenario sample count instead
            # of scoring a timing-dependent prefix.
            latency_deadline = time.monotonic() + 3.0
            while time.monotonic() < latency_deadline:
                delta = remote.run(
                    f"tail -c +{latency_offset + 1} {latency_path} "
                    "2>/dev/null || true", check=False)
                latency_records = []
                for line in delta.splitlines():
                    try:
                        latency_records.append(json.loads(line))
                    except json.JSONDecodeError:
                        pass
                required_latency_samples = (
                    24 if name == "tap-burst" else 1)
                if len(latency_records) >= required_latency_samples:
                    break
                time.sleep(0.1)
        else:
            time.sleep(0.45)
        remote.run("uiopen --url macwshost://performance-snapshot")
        marker, profile = wait_for_profile(remote, previous_marker)
        app_input_latency = summarize_real_app_input_latency(
            latency_records)
        fluid = name in {
            "hover", "drag", "long-drag", "scroll", "scroll-momentum",
            "magnify", "three-up", "three-down", "three-left", "three-right",
            "mission-select",
        }
        results[-1]["profile_marker"] = marker
        results[-1]["performance"] = profile
        results[-1]["app_input_latency"] = app_input_latency
        results[-1]["score"] = score_profile(
            profile, target_pid=(dock_pid if name.startswith("three-")
                                 or name == "mission-select"
                                 else target_pid),
            system_gesture=name.startswith("three-") or
                name == "mission-select",
            require_fluid_metrics=fluid,
            require_click_latency=name == "tap-burst",
            require_system_selection=name == "mission-select",
            app_input_latency=app_input_latency)
    return results


def input_semantic_gate(remote, remote_repo, pid):
    matrix = run_remote_python(remote, remote_repo, "host_input_matrix.py",
                               ["--pid", pid], expect_json=True)
    motion = {}
    for rate in (60, 120):
        motion[str(rate)] = run_remote_python(
            remote, remote_repo, "host_input_motion.py",
            ["--pid", pid, "--duration", 5, "--hz", rate],
            timeout=20, expect_json=True)
    p95_values = [
        item.get("latency_ms", {}).get("p95")
        for item in motion.values()
    ]
    checks = {
        "semantic_matrix": matrix.get("result") == "PASS",
        "motion_60_delivery": motion["60"].get("drag_delivery_hz", 0) >=
            THRESHOLDS["minimum_motion_60_delivery_hz"],
        "motion_120_delivery": motion["120"].get("drag_delivery_hz", 0) >=
            THRESHOLDS["minimum_motion_120_delivery_hz"],
        "bridge_p95_latency": all(
            value is not None and
            value <= THRESHOLDS["maximum_input_bridge_p95_ms"]
            for value in p95_values),
    }
    return {
        "result": "PASS" if all(checks.values()) else "FAIL",
        "checks": checks,
        "matrix": matrix,
        "motion": motion,
    }


def select_motion_source(profile, target_pid, system_gesture):
    sources = profile.get("pipeline", {}).get("source_streams", [])
    if system_gesture:
        candidates = [item for item in sources
                      if item.get("owner_pid") == target_pid and
                      item.get("geometry_updates", 0) > 0]
        key = lambda item: (
            item.get("frame_interval", {}).get("samples", 0),
            item.get("geometry_updates", 0),
            item.get("content_frames", 0),
        )
    else:
        candidates = [item for item in sources
                      if item.get("owner_pid") == target_pid]
        key = lambda item: (
            item.get("content_frames", 0) +
            item.get("geometry_updates", 0),
            item.get("frame_interval", {}).get("samples", 0),
        )
    return max(candidates, key=key) if candidates else {}


def score_profile(profile, *, target_pid, system_gesture=False,
                  require_fluid_metrics=True, require_click_latency=False,
                  minimum_click_samples=None,
                  require_system_selection=False,
                  app_input_latency=None):
    visible = profile.get("visible_presentation", {})
    cadence_gate = cadence_thresholds(profile)
    counters = profile.get("counters", {})
    motion_source = select_motion_source(profile, target_pid, system_gesture)
    transport = profile.get("presentation_transport", {})
    final_composite_active = bool(
        transport.get("final_composite_active", False))
    direct_target = profile.get("direct_drawable", {}).get("target")
    if not isinstance(direct_target, dict) or \
            direct_target.get("owner_pid") != target_pid:
        direct_target = None
    # Mission Control/Spaces is one native compositor animation assembled
    # from several Dock, WindowServer and application layers.  No individual
    # source represents what the user saw; score the final drawable cadence.
    # In final-composite mode the WindowServer-owned base is the presentation
    # authority. Per-window streams remain diagnostic metadata but are no
    # longer pixels painted by the Host, so scoring them would measure the
    # retired reconstruction path rather than what the user saw.
    if system_gesture or final_composite_active:
        motion_metric = visible
    elif direct_target:
        # A direct Catalyst/Metal game frame bypasses the ordinary
        # DisplayStream source cadence.  Score only unique producer sequences
        # that reached MacWSHost's real drawable presentation callback; the
        # Host can otherwise redraw one retained IOSurface many times.
        motion_metric = {
            "active_average_fps": direct_target.get(
                "host_visible_average_fps", 0),
            "one_percent_low_fps": direct_target.get(
                "host_visible_one_percent_low_fps", 0),
            "frame_interval": direct_target.get(
                "host_visible_frame_interval", {}),
        }
    else:
        motion_metric = motion_source
    frame = motion_metric.get("frame_interval", {})
    input_visible = profile.get("pipeline", {}).get(
        "input_dispatch_to_visible_callback", {})
    input_visible_by_kind = profile.get("pipeline", {}).get(
        "input_dispatch_to_visible_by_kind", {})
    checks = {
        "metal_command_errors": counters.get("command_errors", 0) <=
            THRESHOLDS["maximum_command_errors"],
        "input_was_dispatched": counters.get("inputs_sent", 0) > 0,
    }
    if require_fluid_metrics:
        checks.update({
        "motion_active_average_fps":
            motion_metric.get("active_average_fps", 0) >=
            cadence_gate["minimum_active_average_fps"],
        "motion_one_percent_low_fps":
            motion_metric.get("one_percent_low_fps", 0) >=
            cadence_gate["minimum_one_percent_low_fps"],
        "enough_motion_samples": frame.get("samples", 0) >=
            THRESHOLDS["minimum_visible_interval_samples"],
        "input_to_visible_p95":
            input_visible.get("samples", 0) >=
                THRESHOLDS["minimum_input_visible_samples"] and
            input_visible.get("p95_ms") is not None and
            input_visible["p95_ms"] <=
                THRESHOLDS["maximum_input_to_visible_p95_ms"],
        })
    if require_click_latency:
        app_input_latency = app_input_latency or {}
        if minimum_click_samples is None:
            minimum_click_samples = THRESHOLDS[
                "minimum_input_visible_samples"]
        main = app_input_latency.get("producer_to_main", {})
        complete = app_input_latency.get(
            "producer_to_appkit_complete", {})
        checks.update({
            "enough_click_response_samples":
                app_input_latency.get("samples", 0) >=
                    minimum_click_samples,
            "real_app_main_dispatch_p95":
                main.get("p95_ms") is not None and
                main["p95_ms"] <= THRESHOLDS[
                    "maximum_real_app_main_dispatch_p95_ms"],
            "real_app_click_complete_p95":
                complete.get("p95_ms") is not None and
                complete["p95_ms"] <= THRESHOLDS[
                    "maximum_real_app_click_complete_p95_ms"],
        })
    if require_system_selection:
        # Mission Control owns thumbnail clicks inside Dock's native modal
        # controller. No mouseDown is sent to the selected application's
        # NSApplication; the correct end-to-end witness is Tap(kind=6) at the
        # Host boundary to the first newly visible final-composite frame.
        selection = input_visible_by_kind.get("6", {})
        checks.update({
            "system_selection_visible_sample":
                selection.get("samples", 0) >= 1,
            "system_selection_to_visible_p95":
                selection.get("p95_ms") is not None and
                selection["p95_ms"] <=
                    THRESHOLDS["maximum_input_to_visible_p95_ms"],
        })
    return {
        "result": "PASS" if all(checks.values()) else "FAIL",
        "checks": checks,
        "cadence_thresholds": cadence_gate,
        "target_source": motion_source,
        "target_direct_drawable": direct_target,
        "presentation_transport": transport,
        "scored_cadence": (
            "visible_final_composite" if final_composite_active else
            "visible_system_gesture" if system_gesture else
            "target_direct_drawable" if direct_target else
            "target_source"
        ),
        "visible_presentation": visible,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", default="mobile")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--remote-repo",
                        default="/var/jb/var/mobile/MacWSBootingGuide")
    parser.add_argument(
        "--pid", type=int,
        help=("expected focused AppKit PID and semantic-gate target; "
              "defaults to MacWSInputLab"))
    parser.add_argument("--window", type=int, default=0)
    parser.add_argument("--width", type=int, default=1728)
    parser.add_argument("--height", type=int, default=1312)
    parser.add_argument("--skip-system-gestures", action="store_true")
    parser.add_argument(
        "--skip-semantic-gate", action="store_true",
        help=("profile a real application instead of InputLab; keep the "
              "end-to-end Host/DisplayStream measurements but skip the "
              "InputLab-only event log and motion-delivery assertions"))
    parser.add_argument(
        "--scenarios",
        help=("comma-separated subset for an optimization iteration; the "
              "default remains the complete gesture matrix"))
    parser.add_argument("--output", type=pathlib.Path,
                        default=pathlib.Path("/tmp/macws-ui-profile.json"))
    args = parser.parse_args()

    remote = Remote(args.host, args.user, args.port)
    before_thermal = thermal_snapshot(remote)
    if before_thermal["state"] == "critical":
        report = {
            "result": "ABORTED_CRITICAL_THERMAL",
            "device": args.host,
            "thermal_before": before_thermal,
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False,
                                          indent=2) + "\n")
        raise SystemExit(2)

    before_processes = process_snapshot(remote)
    target_pid = args.pid or (
        before_processes["MacWSInputLab"][-1]
        if before_processes["MacWSInputLab"] else 0)
    if target_pid <= 1:
        raise SystemExit("MacWSInputLab is not running and --pid was omitted")
    dock_pid = (0 if args.skip_system_gestures else
                (before_processes["Dock"][-1]
                 if before_processes["Dock"] else 0))

    # Hide both HUDs during the measured workload. The fixed rings remain
    # active, and the explicit snapshot below exports them after the run.
    remote.run("uiopen --url macwshost://performance-hud-off")
    remote.run("uiopen --url macwshost://system-performance-hud-off")
    remote.run("uiopen --url macwshost://performance-reset")
    time.sleep(0.5)
    focus_witness = remote.run(
        "tail -n 500 /var/mobile/Library/Logs/MacWSHost.log | "
        "grep 'performance-profile-target' | tail -n 1",
        check=False).strip()
    focus_match = re.search(r"performance-profile-target pid=(\d+)",
                            focus_witness)
    if not focus_match:
        raise SystemExit(
            "Host did not emit a fresh performance-profile-target witness")
    if focus_match and int(focus_match.group(1)) != target_pid:
        raise SystemExit(
            f"Host focused PID {focus_match.group(1)} does not match "
            f"profile target {target_pid}: {focus_witness}")

    requested_scenarios = ([item.strip() for item in args.scenarios.split(",")
                            if item.strip()] if args.scenarios else None)
    gestures = execute_gesture_suite(remote, dock_pid, target_pid,
                                     requested_scenarios)
    input_gate = (input_semantic_gate(remote, args.remote_repo, target_pid)
                  if not args.skip_semantic_gate else {
                      "result": "SKIPPED_REAL_APP",
                      "reason": ("InputLab event-log semantics are not "
                                 "available inside an unmodified real app"),
                  })
    after_processes = process_snapshot(remote)
    # GUI applications normally run as root in the chroot while this harness
    # connects as mobile. `kill -0` therefore returns EPERM for a healthy
    # target and falsely reports a crash. Read the process table instead; this
    # is the same non-mutating identity witness used by process_snapshot().
    target_alive_after = remote.run(
        f"ps -p {target_pid} -o pid= 2>/dev/null | tr -d ' '",
        check=False).strip() == str(target_pid)
    after_thermal = thermal_snapshot(remote)
    fluid_scenarios = [item for item in gestures
                       if item["scenario"] in {
                           "tap-burst",
                           "hover", "drag", "long-drag", "scroll",
                           "scroll-momentum", "magnify", "three-up",
                           "mission-select",
                           "three-down", "three-left", "three-right",
                       }]
    profile_score = {
        "result": "PASS" if fluid_scenarios and all(
            item["score"]["result"] == "PASS"
            for item in fluid_scenarios) else "FAIL",
        "fluid_scenarios": {
            item["scenario"]: item["score"] for item in fluid_scenarios
        },
    }
    stability_names = [
        "WindowServer", "macwsdisplayd", "MacWSHost", "UIKitSystem",
        "MacWSInputLab",
    ]
    if dock_pid > 1:
        stability_names.append("Dock")
    stable_processes = all(
        set(before_processes[name]).issubset(after_processes[name])
        for name in stability_names)
    checks = {
        "profile": profile_score["result"] == "PASS",
        "input": (input_gate["result"] == "PASS" or
                  (args.skip_semantic_gate and
                   input_gate["result"] == "SKIPPED_REAL_APP")),
        "target_process_stability": target_alive_after,
        "process_stability": stable_processes,
        "thermal_not_critical": after_thermal["state"] != "critical",
    }
    report = {
        "schema": "macws-ui-regression-v2",
        "result": "PASS" if all(checks.values()) else "FAIL",
        "device": args.host,
        "target_pid": target_pid,
        "target_window": args.window,
        "target_alive_after": target_alive_after,
        "host_focus_witness": focus_witness,
        "thresholds": THRESHOLDS,
        "checks": checks,
        "profile_score": profile_score,
        "host_profile": {
            "schema": "macws-ui-scenario-profiles-v2",
            "profiles": {
                item["scenario"]: item["performance"] for item in gestures
            },
        },
        "input_gate": input_gate,
        "gesture_scenarios": gestures,
        "processes_before": before_processes,
        "processes_after": after_processes,
        "thermal_before": before_thermal,
        "thermal_after": after_thermal,
        "measurement_limitations": [
            "Wire replay excludes physical finger-to-UIKit recognizer latency.",
            "A real-finger run can use the same reset/export controls to add that boundary.",
            "A MacBook run is calibration-only and is not required for this fixed-floor gate.",
            ("InputLab-only event-name and synthetic delivery-rate checks "
             "were skipped for this real application."
             if args.skip_semantic_gate else
             "InputLab semantic and delivery-rate gates were included."),
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({
        "result": report["result"],
        "output": str(args.output),
        "profile": profile_score,
        "input": input_gate["result"],
        "thermal": after_thermal,
    }, ensure_ascii=False, indent=2))
    if report["result"] != "PASS":
        raise SystemExit(2)


if __name__ == "__main__":
    main()
