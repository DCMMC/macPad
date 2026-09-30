"""Low-perturbation frame, power, thermal and memory profiler for MacWS.

Run this on the controlling Mac after placing the representative workload in
the foreground.  MacWSHost supplies actual drawable presentation timestamps;
one finite powermetrics process supplies CPU/GPU power on the same wall-clock
interval.  Expensive VM-region walks are limited to the two interval
boundaries, never sampled once per frame or once per second.

Example (reuse an authenticated SSH control socket):

    python3 misc/macws_frame_power_profile.py \
      --host 192.168.1.2 --user root --port 2222 \
      --control-path /tmp/macpad-power-lan-ssh.sock \
      --label vscode-aquarium-60k --seconds 15 \
      --output /tmp/macws-aquarium-60k.json
"""

from __future__ import annotations

import argparse
import atexit
import hashlib
import json
import pathlib
import re
import shlex
import statistics
import struct
import subprocess
import sys
import time


HOST_PROFILE = "/var/mobile/Library/Logs/MacWSPerformance/latest.json"
HOST_SCREENSHOT = "/var/mobile/Library/Logs/MacWSHost-rendered.png"
ACTIVITY_PATH = "/var/mnt/rootfs/private/tmp/macws_render_activity"
AUTHORITY_PATH = "/var/mnt/rootfs/private/tmp/macws_render_authority"
ACTIVITY_MAGIC = 0x4D575241
AUTHORITY_MAGIC = 0x4D575255
PROFILE_SCHEMA = "macws-frame-power-profile-v1"

PROCESS_NAMES = {
    "WindowServer", "MacWSHost", "macwsdisplayd", "Dock", "Finder",
    "Code", "Code Helper (GPU)", "Electron", "Google Chrome Helper (GPU)",
    "Stray-Mac-Shipping", "7DaysToDie", "7DaysToDie.app",
}
FOOTPRINT_NAMES = {"WindowServer", "MacWSHost", "macwsdisplayd"}


class Remote:
    def __init__(self, host: str, user: str, port: int,
                 control_path: str | None):
        self.host = host
        self.user = user
        self.port = port
        self.control_path = control_path
        self.base = [
            "ssh", "-p", str(port), "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
        ]
        if control_path:
            self.base += ["-S", control_path]
        self.base.append(f"{user}@{host}")

    def run_result(self, command: str, *, timeout: float = 45):
        return subprocess.run(
            self.base + [command], capture_output=True, text=True,
            timeout=timeout,
        )

    def run(self, command: str, *, timeout: float = 45,
            check: bool = True):
        result = self.run_result(command, timeout=timeout)
        if check and result.returncode:
            raise RuntimeError(
                f"remote command failed rc={result.returncode}: "
                f"{result.stderr.strip()}\ncommand={command}"
            )
        return result.stdout

    def popen(self, command: str):
        return subprocess.Popen(
            self.base + [command], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True,
        )

    def copy_from(self, source: str, destination: pathlib.Path):
        command = [
            "scp", "-q", "-P", str(self.port), "-o", "BatchMode=yes",
        ]
        if self.control_path:
            command += ["-o", f"ControlPath={self.control_path}"]
        command += [f"{self.user}@{self.host}:{source}", str(destination)]
        subprocess.run(command, check=True, timeout=30)


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1,
                       int(len(ordered) * fraction + 0.999999) - 1))
    return ordered[index]


def summarize_numbers(values: list[float], suffix: str = "") -> dict:
    if not values:
        return {"samples": 0}
    return {
        "samples": len(values),
        f"minimum{suffix}": min(values),
        f"mean{suffix}": statistics.fmean(values),
        f"p50{suffix}": percentile(values, 0.50),
        f"p95{suffix}": percentile(values, 0.95),
        f"maximum{suffix}": max(values),
    }


def parse_powermetrics(text: str) -> list[dict]:
    samples = []
    starts = list(re.finditer(
        r"(?m)^\*\*\* Sampled system activity .*?\*\*\*[ \t]*$", text))
    for index, start in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(text)
        block = text[start.start():end]

        def number(pattern: str) -> float | None:
            match = re.search(pattern, block, re.M)
            return float(match.group(1)) if match else None

        pressure = re.search(
            r"^Current pressure level:[ \t]*([^\n]+?)[ \t]*$", block, re.M)
        requested = re.search(
            r"^GPU requested frequency:[ \t]*(\([^\n]+\))[ \t]*$",
            block, re.M)
        sample = {
            "sample_elapsed_ms": number(r"\(([0-9.]+)ms elapsed\)"),
            "cpu_power_mw": number(r"^CPU Power:[ \t]*([0-9.]+) mW"),
            "gpu_power_mw": number(r"^GPU Power:[ \t]*([0-9.]+) mW"),
            "combined_power_mw": number(
                r"^Combined Power \(CPU \+ GPU \+ ANE\):[ \t]*([0-9.]+) mW"),
            "gpu_active_frequency_mhz": number(
                r"^GPU active frequency:[ \t]*([0-9.]+) MHz"),
            "gpu_active_residency_percent": number(
                r"^GPU active residency:[ \t]*([0-9.]+)%"),
            "e_cluster_active_residency_percent": number(
                r"^E-Cluster HW active residency:[ \t]*([0-9.]+)%"),
            "p_cluster_active_residency_percent": number(
                r"^P-Cluster HW active residency:[ \t]*([0-9.]+)%"),
            "thermal_pressure": pressure.group(1).strip()
                if pressure else None,
            "gpu_requested_frequency_histogram": requested.group(1)
                if requested else None,
        }
        if any(value is not None for key, value in sample.items()
               if key.endswith("_mw")):
            samples.append(sample)
    return samples


def summarize_power(samples: list[dict]) -> dict:
    result = {"samples": len(samples)}
    for key in (
        "cpu_power_mw", "gpu_power_mw", "combined_power_mw",
        "gpu_active_frequency_mhz", "gpu_active_residency_percent",
        "e_cluster_active_residency_percent",
        "p_cluster_active_residency_percent",
    ):
        values = [float(sample[key]) for sample in samples
                  if sample.get(key) is not None]
        result[key] = summarize_numbers(values)
    result["thermal_pressure_samples"] = [
        sample["thermal_pressure"] for sample in samples
        if sample.get("thermal_pressure")
    ]
    result["sampled_seconds"] = sum(
        sample.get("sample_elapsed_ms", 0.0) or 0.0 for sample in samples
    ) / 1000.0
    result["source"] = (
        "powermetrics --samplers cpu_power,gpu_power,thermal"
    )
    return result


def parse_size(value: str) -> int | None:
    match = re.fullmatch(r"([0-9.]+)\s*([KMG]?B)", value.strip())
    if not match:
        return None
    scale = {"B": 1, "KB": 1024, "MB": 1024 ** 2, "GB": 1024 ** 3}
    return round(float(match.group(1)) * scale[match.group(2)])


def parse_footprint(text: str) -> dict:
    current = re.search(r"(?m)^\s*phys_footprint:\s*([0-9.]+\s*[KMG]?B)", text)
    peak = re.search(r"(?m)^\s*phys_footprint_peak:\s*([0-9.]+\s*[KMG]?B)", text)
    iosurface = re.search(
        r"(?m)^\s*([0-9.]+\s*[KMG]?B)\s+[^\n]*\sIOSurface\s*$", text)
    accelerator = re.search(
        r"(?m)^\s*([0-9.]+\s*[KMG]?B)\s+[^\n]*\sIOAccelerator\s*$", text)
    return {
        "physical_footprint_bytes": parse_size(current.group(1))
            if current else None,
        "peak_physical_footprint_bytes": parse_size(peak.group(1))
            if peak else None,
        "iosurface_bytes": parse_size(iosurface.group(1))
            if iosurface else None,
        "ioaccelerator_bytes": parse_size(accelerator.group(1))
            if accelerator else None,
    }


def parse_cpu_time(value: str) -> float | None:
    """Parse Darwin ps TIME values such as 7:37.36 or 1-02:03:04.50."""
    match = re.fullmatch(
        r"(?:(\d+)-)?(?:(\d+):)?(\d+):([0-9]+(?:\.[0-9]+)?)",
        value.strip())
    if not match:
        return None
    days = int(match.group(1) or 0)
    hours = int(match.group(2) or 0)
    minutes = int(match.group(3))
    seconds = float(match.group(4))
    return days * 86400.0 + hours * 3600.0 + minutes * 60.0 + seconds


def thermal_snapshot(remote: Remote) -> dict:
    raw = remote.run(
        "/var/jb/usr/macOS/bin/macwsthermal 2>&1 || true",
        check=False, timeout=10).strip()
    state = re.search(r"thermal-state=([a-z]+)", raw)
    temperature = re.search(r"effective-temp-centic=(\d+)", raw)
    return {
        "captured_wall_time": time.time(),
        "state": state.group(1) if state else "unknown",
        "temperature_c": (int(temperature.group(1)) / 100.0
                          if temperature else None),
        "witness": raw,
    }


def process_snapshot(remote: Remote, footprint: bool,
                     target_pid: int = 0) -> dict:
    raw = remote.run(
        "/bin/ps -axo pid=,ppid=,%cpu=,time=,rss=,vsz=,comm=", timeout=15)
    captured_wall_time = time.time()
    all_processes = []
    for line in raw.splitlines():
        fields = line.strip().split(None, 6)
        if len(fields) != 7 or not fields[0].isdigit():
            continue
        pid, ppid, cpu, cpu_time, rss, vsz, command = fields
        basename = pathlib.PurePosixPath(command).name
        all_processes.append({
            "pid": int(pid), "ppid": int(ppid), "cpu_percent": float(cpu),
            "cpu_time_seconds": parse_cpu_time(cpu_time),
            "rss_bytes": int(rss) * 1024, "vsz_bytes": int(vsz) * 1024,
            "name": basename, "command": command,
        })
    selected_pids = {
        process["pid"] for process in all_processes
        if process["name"] in PROCESS_NAMES or any(
            token in process["name"] for token in (
                "Code Helper", "Chrome Helper", "7Days"))
    }
    if target_pid > 1:
        target_tree = {target_pid}
        changed = True
        while changed:
            changed = False
            for process in all_processes:
                if (process["pid"] not in target_tree and
                        process["ppid"] in target_tree):
                    target_tree.add(process["pid"])
                    changed = True
        selected_pids.update(target_tree)
    processes = [process for process in all_processes
                 if process["pid"] in selected_pids]
    footprints = {}
    if footprint:
        for process in processes:
            if process["name"] not in FOOTPRINT_NAMES:
                continue
            result = remote.run_result(
                f"timeout 15 /usr/bin/footprint -p {process['pid']}",
                timeout=20)
            footprints[str(process["pid"])] = {
                "name": process["name"],
                "status": result.returncode,
                **parse_footprint(result.stdout),
            }
    return {
        "captured_wall_time": captured_wall_time,
        "processes": processes,
        "footprints": footprints,
    }


def process_cpu_summary(before: dict, after: dict,
                        target_pid: int = 0) -> dict:
    """Derive exact interval CPU from cumulative ps TIME counters.

    A value of 100% means one core was busy for the complete interval.  The
    target_tree role includes the selected process and all descendants visible
    at the closing boundary, which keeps Chromium/Electron GPU and renderer
    helpers attributable to their logical application instead of hiding them
    behind one low-CPU parent.
    """
    elapsed = (float(after.get("captured_wall_time", 0.0)) -
               float(before.get("captured_wall_time", 0.0)))
    if elapsed <= 0.0:
        return {"elapsed_seconds": None, "processes": [], "roles": {}}
    before_by_pid = {item["pid"]: item for item in before.get("processes", [])}
    after_processes = after.get("processes", [])
    after_by_pid = {item["pid"]: item for item in after_processes}

    target_tree = set()
    if target_pid > 1 and target_pid in after_by_pid:
        target_tree.add(target_pid)
        changed = True
        while changed:
            changed = False
            for item in after_processes:
                if (item["pid"] not in target_tree and
                        item["ppid"] in target_tree):
                    target_tree.add(item["pid"])
                    changed = True

    processes = []
    for pid, current in after_by_pid.items():
        previous = before_by_pid.get(pid)
        current_time = current.get("cpu_time_seconds")
        previous_time = previous.get("cpu_time_seconds") if previous else None
        if not isinstance(current_time, (int, float)) or not isinstance(
                previous_time, (int, float)):
            continue
        delta = current_time - previous_time
        if delta < 0.0:
            continue
        processes.append({
            "pid": pid,
            "ppid": current["ppid"],
            "name": current["name"],
            "cpu_time_delta_seconds": delta,
            "average_cpu_percent": delta / elapsed * 100.0,
            "target_descendant": pid in target_tree,
        })
    processes.sort(key=lambda item: item["average_cpu_percent"], reverse=True)

    role_members = {
        "target_tree": target_tree,
        "macws_host": {item["pid"] for item in after_processes
                        if item["name"] == "MacWSHost"},
        "window_server": {item["pid"] for item in after_processes
                           if item["name"] == "WindowServer"},
        "displayd": {item["pid"] for item in after_processes
                      if item["name"] == "macwsdisplayd"},
    }
    roles = {}
    for role, pids in role_members.items():
        selected = [item for item in processes if item["pid"] in pids]
        roles[role] = {
            "pids": sorted(pids),
            "processes": len(selected),
            "cpu_time_delta_seconds": sum(
                item["cpu_time_delta_seconds"] for item in selected),
            "average_cpu_percent": sum(
                item["average_cpu_percent"] for item in selected),
        }
    return {
        "elapsed_seconds": elapsed,
        "unit_note": "100 percent equals one fully busy CPU core",
        "processes": processes,
        "roles": roles,
    }


def profile_marker(remote: Remote) -> str:
    return remote.run(
        f"stat -c '%Y:%s:%i' {HOST_PROFILE} 2>/dev/null || true",
        check=False).strip()


def fresh_host_profile(remote: Remote, previous: str,
                       timeout: float = 10.0) -> dict:
    remote.run("uiopen --url macwshost://performance-snapshot", timeout=10)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        marker = profile_marker(remote)
        if marker and marker != previous:
            return json.loads(remote.run(f"cat {HOST_PROFILE}"))
        time.sleep(0.15)
    raise RuntimeError("MacWSHost did not export a fresh performance profile")


CADENCE_STREAM_SCRIPT = r'''
import json, os, struct, sys, time
activity_path, authority_path, seconds, interval = sys.argv[1:]
seconds, interval = float(seconds), float(interval)
deadline = time.monotonic() + seconds
def read_record(path, fmt, fields):
    try:
        with open(path, "rb", buffering=0) as source:
            raw = source.read(struct.calcsize(fmt))
        if len(raw) != struct.calcsize(fmt):
            return {"state":"short", "bytes":len(raw)}
        return dict(zip(fields, struct.unpack(fmt, raw)))
    except FileNotFoundError:
        return {"state":"missing"}
    except OSError as error:
        return {"state":"error", "errno":error.errno}
def read_activity(path):
    try:
        with open(path, "rb", buffering=0) as source:
            raw = source.read(32)
        if len(raw) == 32:
            fields = ("magic", "version", "size", "timestamp_ns",
                      "target_pace_us", "producer_pid", "present_sequence")
            return dict(zip(fields, struct.unpack("<IHHQIiQ", raw)))
        if len(raw) == 24:
            fields = ("magic", "version", "size", "timestamp_ns",
                      "target_pace_us", "producer_pid")
            record = dict(zip(fields, struct.unpack("<IHHQIi", raw)))
            record["present_sequence"] = 0
            return record
        return {"state":"short", "bytes":len(raw)}
    except FileNotFoundError:
        return {"state":"missing"}
    except OSError as error:
        return {"state":"error", "errno":error.errno}
while True:
    # Procursus Python's time.monotonic_ns() is process-relative on this
    # jailbreak, while Darwin time.clock_gettime_ns(CLOCK_MONOTONIC) matches
    # the cross-process timestamps written by chrooted Metal/displayd.
    now = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    activity = read_activity(activity_path)
    authority = read_record(authority_path, "<IHHQiIII", (
        "magic", "version", "size", "timestamp_ns", "owner_pid",
        "layer_window_id", "width", "height"))
    for record in (activity, authority):
        stamp = record.get("timestamp_ns")
        record["age_ms"] = ((now - stamp) / 1e6
                            if stamp and now >= stamp else None)
    print(json.dumps({"monotonic_ns":now, "wall_time":time.time(),
                      "activity":activity, "authority":authority},
                     separators=(",", ":")), flush=True)
    if time.monotonic() >= deadline:
        break
    time.sleep(interval)
'''


def start_cadence_stream(remote: Remote, seconds: float,
                         interval: float = 0.25):
    command = (
        "/var/jb/usr/bin/python3 -u -c " + shlex.quote(CADENCE_STREAM_SCRIPT) +
        " " + " ".join(shlex.quote(str(value)) for value in (
            ACTIVITY_PATH, AUTHORITY_PATH, seconds, interval))
    )
    return remote.popen(command)


def start_powermetrics(remote: Remote, seconds: int):
    interval_ms = 1000
    samples = max(1, int(seconds))
    inside = (
        "/usr/bin/powermetrics --samplers cpu_power,gpu_power,thermal "
        f"-n {samples} -i {interval_ms}"
    )
    command = (
        "sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c " +
        shlex.quote(inside)
    )
    return remote.popen(command)


def cadence_summary(samples: list[dict]) -> dict:
    valid_activity = [sample for sample in samples
                      if sample.get("activity", {}).get("magic") == ACTIVITY_MAGIC]
    valid_authority = [sample for sample in samples
                       if sample.get("authority", {}).get("magic") == AUTHORITY_MAGIC]
    paces = [sample["activity"].get("target_pace_us")
             for sample in valid_activity
             if sample["activity"].get("target_pace_us")]
    fresh_activity = [sample for sample in valid_activity
                      if sample["activity"].get("age_ms") is not None and
                      sample["activity"]["age_ms"] <= 2000.0]
    fresh_authority = [sample for sample in valid_authority
                       if sample["authority"].get("age_ms") is not None and
                      sample["authority"]["age_ms"] <= 2000.0]
    producer_rates = []
    previous = None
    for sample in valid_activity:
        activity = sample["activity"]
        sequence = int(activity.get("present_sequence", 0) or 0)
        stamp = int(activity.get("timestamp_ns", 0) or 0)
        pid = int(activity.get("producer_pid", 0) or 0)
        if (previous and sequence > previous[0] and
                stamp > previous[1] and pid == previous[2]):
            producer_rates.append(
                (sequence - previous[0]) * 1_000_000_000.0 /
                (stamp - previous[1]))
        if sequence and stamp:
            previous = (sequence, stamp, pid)
    return {
        "samples": len(samples),
        "valid_activity_samples": len(valid_activity),
        "fresh_activity_samples": len(fresh_activity),
        "valid_authority_samples": len(valid_authority),
        "fresh_authority_samples": len(fresh_authority),
        "target_pace_us": summarize_numbers([float(value) for value in paces]),
        "requested_fps": summarize_numbers(
            [1_000_000.0 / value for value in paces if value > 0]),
        "producer_present_fps": summarize_numbers(producer_rates),
        "producer_present_sequence": {
            "first": next((int(sample["activity"].get(
                "present_sequence", 0) or 0) for sample in valid_activity
                if int(sample["activity"].get(
                    "present_sequence", 0) or 0) > 0), 0),
            "last": next((int(sample["activity"].get(
                "present_sequence", 0) or 0) for sample in
                reversed(valid_activity) if int(sample["activity"].get(
                    "present_sequence", 0) or 0) > 0), 0),
        },
        "producer_pids": sorted({
            int(sample["activity"].get("producer_pid", 0))
            for sample in valid_activity
            if int(sample["activity"].get("producer_pid", 0)) > 1
        }),
        "authority_owner_pids": sorted({
            int(sample["authority"].get("owner_pid", 0))
            for sample in valid_authority
            if int(sample["authority"].get("owner_pid", 0)) > 1
        }),
    }


def scored_cadence(host_profile: dict, target_pid: int) -> dict:
    direct = host_profile.get("direct_drawable", {}).get("target")
    if isinstance(direct, dict) and (
            target_pid <= 1 or direct.get("owner_pid") == target_pid):
        return {
            "source": "target_direct_drawable",
            "average_fps": direct.get("host_visible_average_fps", 0.0),
            "one_percent_low_fps": direct.get(
                "host_visible_one_percent_low_fps", 0.0),
            "frame_interval": direct.get("host_visible_frame_interval", {}),
            "unique_visible_frames": direct.get(
                "host_unique_frames_presented", 0),
        }
    streams = host_profile.get("pipeline", {}).get("source_streams", [])
    candidates = [item for item in streams
                  if target_pid <= 1 or item.get("owner_pid") == target_pid]
    if candidates:
        source = max(candidates, key=lambda item: (
            item.get("content_frames", 0),
            item.get("frame_interval", {}).get("samples", 0)))
        return {
            "source": "target_source_stream",
            "owner_pid": source.get("owner_pid"),
            "average_fps": source.get("active_average_fps", 0.0),
            "one_percent_low_fps": source.get("one_percent_low_fps", 0.0),
            "frame_interval": source.get("frame_interval", {}),
            "unique_visible_frames": source.get("content_frames", 0),
        }
    visible = host_profile.get("visible_presentation", {})
    observed = visible.get("observed_frame_interval", {})
    mean = observed.get("mean_ms")
    p99 = observed.get("p99_ms")
    return {
        "source": "host_visible_presentation",
        "average_fps": 1000.0 / mean if isinstance(mean, (int, float)) and mean > 0 else 0.0,
        "one_percent_low_fps": 1000.0 / p99 if isinstance(p99, (int, float)) and p99 > 0 else 0.0,
        "frame_interval": observed,
        "unique_visible_frames": host_profile.get("counters", {}).get(
            "frames_presented", 0),
    }


def scheduler_summary(host_profile: dict) -> dict:
    counters = host_profile.get("counters", {})
    direct = host_profile.get("direct_drawable", {}).get("target")
    direct = direct if isinstance(direct, dict) else {}
    elapsed = host_profile.get("elapsed_s")
    ticks = counters.get("direct_drawable_scheduler_ticks")
    empty = counters.get("direct_drawable_scheduler_empty_ticks")
    received = direct.get("unique_frames_received")
    presented = direct.get("host_unique_frames_presented")

    def rate(count):
        return (count / elapsed if isinstance(count, (int, float)) and
                isinstance(elapsed, (int, float)) and elapsed > 0 else None)

    return {
        "panel_target_fps": host_profile.get("target", {}).get(
            "display_maximum_fps"),
        "scheduler_ticks": ticks,
        "scheduler_tick_hz": rate(ticks),
        "scheduler_empty_ticks": empty,
        "scheduler_empty_tick_hz": rate(empty),
        "scheduler_empty_percent": (
            empty / ticks * 100.0
            if isinstance(empty, (int, float)) and
            isinstance(ticks, (int, float)) and ticks > 0 else None),
        "producer_delivered_fps": direct.get(
            "producer_delivered_average_fps"),
        "host_visible_fps": direct.get("host_visible_average_fps"),
        "unique_frames_received": received,
        "unique_frames_presented": presented,
        "delivery_retention_percent": (
            presented / received * 100.0
            if isinstance(received, (int, float)) and received > 0 and
            isinstance(presented, (int, float)) else None),
    }


def efficiency_summary(power: dict, cadence: dict,
                       elapsed_seconds: float) -> dict:
    values = power.get("combined_power_mw", {})
    mean_power = values.get("mean")
    frames = cadence.get("unique_visible_frames", 0) or 0
    average_fps = cadence.get("average_fps", 0.0) or 0.0
    sampled_seconds = power.get("sampled_seconds", elapsed_seconds)
    energy_mj = (mean_power * sampled_seconds
                 if isinstance(mean_power, (int, float)) else None)
    return {
        "mean_combined_power_mw": mean_power,
        "sampled_seconds": sampled_seconds,
        "estimated_interval_energy_mj": energy_mj,
        "unique_visible_frames": frames,
        "steady_state_energy_per_visible_frame_mj": (
            mean_power / average_fps
            if isinstance(mean_power, (int, float)) and average_fps > 0
            else None),
        "note": (
            "Steady-state CPU+GPU+ANE milliwatts divided by actual Host-visible "
            "frames/second gives millijoules/frame without counting SSH/chroot "
            "observer startup; static-scene intervals intentionally have few "
            "frames and should be compared by mean power instead."
        ),
    }


def memory_delta(before: dict, after: dict) -> list[dict]:
    before_by_key = {(item["name"], item["pid"]): item
                     for item in before["processes"]}
    rows = []
    for item in after["processes"]:
        prior = before_by_key.get((item["name"], item["pid"]))
        if not prior:
            continue
        row = {
            "name": item["name"], "pid": item["pid"],
            "rss_delta_bytes": item["rss_bytes"] - prior["rss_bytes"],
        }
        first = before.get("footprints", {}).get(str(item["pid"]), {})
        last = after.get("footprints", {}).get(str(item["pid"]), {})
        if (first.get("physical_footprint_bytes") is not None and
                last.get("physical_footprint_bytes") is not None):
            row["physical_footprint_delta_bytes"] = (
                last["physical_footprint_bytes"] -
                first["physical_footprint_bytes"])
        if (first.get("iosurface_bytes") is not None and
                last.get("iosurface_bytes") is not None):
            row["iosurface_delta_bytes"] = (
                last["iosurface_bytes"] - first["iosurface_bytes"])
        rows.append(row)
    return rows


def run_workload(command: str | None):
    if not command:
        return None
    return subprocess.Popen(
        shlex.split(command), stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True,
    )


def finish_workload(process, timeout: float) -> dict | None:
    if process is None:
        return None
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            stdout, stderr = process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate(timeout=3)
    parsed = None
    start = stdout.find("{")
    if start >= 0:
        try:
            parsed = json.loads(stdout[start:])
        except json.JSONDecodeError:
            pass
    return {
        "returncode": process.returncode,
        "stdout": stdout[-20000:],
        "stderr": stderr[-10000:],
        "json": parsed,
    }


def run_cleanup_command(command: str | None) -> dict | None:
    if not command:
        return None
    try:
        result = subprocess.run(
            shlex.split(command), capture_output=True, text=True, timeout=30,
        )
        return {
            "returncode": result.returncode,
            "stdout": result.stdout[-5000:],
            "stderr": result.stderr[-5000:],
        }
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"returncode": None, "error": str(error)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", default="root")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--control-path")
    parser.add_argument("--label", required=True)
    parser.add_argument("--seconds", type=int, default=15)
    parser.add_argument("--target-pid", type=int, default=0)
    parser.add_argument(
        "--workload-command",
        help=("optional local argv string launched immediately after Host "
              "reset; shell syntax is not interpreted"))
    parser.add_argument(
        "--cleanup-command",
        help=("optional local argv string run after all scored evidence is "
              "captured and also at interpreter exit after a failed run; "
              "shell syntax is not interpreted"))
    parser.add_argument("--require-nominal", action="store_true")
    parser.add_argument("--screenshot", action="store_true")
    parser.add_argument("--skip-footprint", action="store_true")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if not 3 <= args.seconds <= 60:
        parser.error("--seconds must be between 3 and 60")

    cleanup_state = {"ran": False, "result": None}

    def cleanup_once():
        if cleanup_state["ran"] or not args.cleanup_command:
            return cleanup_state["result"]
        cleanup_state["ran"] = True
        cleanup_state["result"] = run_cleanup_command(args.cleanup_command)
        if cleanup_state["result"].get("returncode") != 0:
            print(
                "MacWS profiler cleanup command failed: " +
                json.dumps(cleanup_state["result"], ensure_ascii=False),
                file=sys.stderr,
            )
        return cleanup_state["result"]

    atexit.register(cleanup_once)

    remote = Remote(args.host, args.user, args.port, args.control_path)
    started_wall = time.time()
    thermal_before = thermal_snapshot(remote)
    if args.require_nominal and thermal_before["state"] != "nominal":
        raise SystemExit(
            f"thermal precondition failed: {thermal_before['witness']}")
    process_before = process_snapshot(
        remote, not args.skip_footprint, args.target_pid)
    previous_profile = profile_marker(remote)
    reset_url = "macwshost://performance-reset"
    if args.target_pid > 1:
        reset_url += f"?pid={args.target_pid}"
    remote.run("uiopen --url " + shlex.quote(reset_url), timeout=10)
    time.sleep(0.35)

    process_cpu_before = process_snapshot(remote, False, args.target_pid)
    cadence_process = start_cadence_stream(
        remote, args.seconds + 1.0, interval=0.25)
    power_process = start_powermetrics(remote, args.seconds)
    workload_process = run_workload(args.workload_command)
    measurement_started = time.monotonic()
    power_stdout, power_stderr = power_process.communicate(
        timeout=args.seconds + 20)
    measured_elapsed = time.monotonic() - measurement_started
    process_cpu_after = process_snapshot(remote, False, args.target_pid)
    workload = finish_workload(workload_process, 5.0)
    cadence_stdout, cadence_stderr = cadence_process.communicate(timeout=8)

    cadence_samples = []
    for line in cadence_stdout.splitlines():
        try:
            cadence_samples.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    power_samples = parse_powermetrics(power_stdout)
    host_profile = fresh_host_profile(remote, previous_profile)
    process_after = process_snapshot(
        remote, not args.skip_footprint, args.target_pid)
    thermal_after = thermal_snapshot(remote)
    cadence = scored_cadence(host_profile, args.target_pid)
    scheduler = scheduler_summary(host_profile)
    power = summarize_power(power_samples)

    screenshot = None
    if args.screenshot:
        screenshot_path = args.output.with_suffix(".png")
        remote.run("uiopen --url macwshost://screenshot-rendered", timeout=10)
        time.sleep(1.0)
        remote.copy_from(HOST_SCREENSHOT, screenshot_path)
        payload = screenshot_path.read_bytes()
        screenshot = {
            "path": str(screenshot_path), "bytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        }

    cleanup = cleanup_once()

    result = {
        "schema": PROFILE_SCHEMA,
        "label": args.label,
        "device": {"host": args.host, "user": args.user, "port": args.port},
        "measurement": {
            "started_wall_time": started_wall,
            "requested_seconds": args.seconds,
            "elapsed_seconds": measured_elapsed,
            "target_pid": args.target_pid,
        },
        "cadence": cadence,
        "presentation_scheduler": scheduler,
        "host_profile": host_profile,
        "power": power,
        "power_samples": power_samples,
        "efficiency": efficiency_summary(power, cadence, measured_elapsed),
        "render_control": cadence_summary(cadence_samples),
        "render_control_samples": cadence_samples,
        "thermal_before": thermal_before,
        "thermal_after": thermal_after,
        "process_before": process_before,
        "process_after": process_after,
        "process_cpu": process_cpu_summary(
            process_cpu_before, process_cpu_after, args.target_pid),
        "memory_delta": memory_delta(process_before, process_after),
        "workload": workload,
        "cleanup": cleanup,
        "screenshot": screenshot,
        "observer_errors": {
            "powermetrics_stderr": power_stderr[-5000:],
            "cadence_stderr": cadence_stderr[-5000:],
        },
        "acceptance_inputs": {
            "panel_target_fps": host_profile.get("target", {}).get(
                "display_maximum_fps"),
            "command_errors": host_profile.get("counters", {}).get(
                "command_errors"),
            "thermal_pressure_all_nominal": all(
                value.lower() == "nominal"
                for value in power.get("thermal_pressure_samples", [])),
        },
        "measurement_notes": [
            "Host cadence uses actual CAMetalDrawable presentation callbacks.",
            "Power is CPU+GPU+ANE package power, not wall-adapter draw.",
            "Per-role CPU uses cumulative ps TIME deltas over the scored interval.",
            "footprint runs only before and after the scored interval.",
            "A valid visual screenshot is required before calling a run stable.",
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({
        "schema": PROFILE_SCHEMA,
        "output": str(args.output),
        "cadence": cadence,
        "presentation_scheduler": scheduler,
        "power": {
            "samples": power["samples"],
            "cpu_mean_mw": power["cpu_power_mw"].get("mean"),
            "gpu_mean_mw": power["gpu_power_mw"].get("mean"),
            "combined_mean_mw": power["combined_power_mw"].get("mean"),
        },
        "efficiency": result["efficiency"],
        "temperature_c": {
            "before": thermal_before["temperature_c"],
            "after": thermal_after["temperature_c"],
        },
        "command_errors": result["acceptance_inputs"]["command_errors"],
    }, ensure_ascii=False, indent=2))
    if not power_samples:
        raise SystemExit(2)
    if cleanup and cleanup.get("returncode") != 0:
        raise SystemExit(3)


if __name__ == "__main__":
    main()
