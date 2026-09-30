# MacWS UI Performance Profiler and Gesture Replay (2026-08-11)

## Outcome

MacWS now has a production-capable UI profiler rather than relying on process
CPU, screenshots, or subjective statements such as “looks smoother”. It
combines two independent layers:

1. an optional Apple QuartzCore RenderServer HUD, compatible with the mechanism
   used by [CAPerfHUD](https://github.com/khanhduytran0/CAPerfHUD); and
2. a MacWS-specific per-Scene profiler that measures the complete
   DisplayStream/IOSurface/Host-Metal/visible-drawable path and exports
   comparable JSON.

The first complete fixed-floor run is intentionally **FAIL**, not a cosmetic
PASS. Input transport and process stability passed, while visible fluidity and
tail latency did not yet meet the project targets. This gives subsequent work
an exact optimization boundary.

## Frame, power, thermal, and memory gate (2026-09-30)

`misc/macws_frame_power_profile.py` is the representative sustained-workload
gate for 120 Hz and power work. It aligns six witnesses in one bounded JSON
interval:

- unique producer sequence and producer completion time;
- authenticated Host receipt, Metal submission, and real drawable-presented
  callback for that exact sequence;
- the MTK panel-clock callback rate and empty-tick rate;
- one finite `powermetrics --samplers cpu_power,gpu_power,thermal` process;
- process RSS plus `footprint`/IOSurface snapshots only at the two interval
  boundaries, followed by an optional rendered-drawable PNG; and
- cumulative process CPU-time deltas for the target application tree,
  MacWSHost, WindowServer, and macwsdisplayd. In this report, 100% means one
  fully occupied CPU core.

The harness deliberately does not poll `footprint` during the scored interval.
That walk is too invasive to run per frame, and would contaminate the power
and cadence result it is intended to measure.

Example for a 120 Hz autonomous WebGL/game workload:

```bash
python3 misc/macws_frame_power_profile.py \
  --host 192.168.1.2 --user root --port 2222 \
  --control-path /tmp/macpad-power-lan-ssh.sock \
  --label aquarium-1k --seconds 30 --target-pid 12345 \
  --require-nominal --screenshot \
  --cleanup-command "python3 misc/macws_vscode_web_control.py --host 192.168.1.2 --port 2222 --control-path /tmp/macpad-power-lan-ssh.sock close" \
  --output /tmp/macws-aquarium-1k.json
```

For a VS Code web workload, the cleanup command is part of the measurement
contract rather than optional housekeeping. It closes the final socket-owned
Simple Browser webview after screenshots, process snapshots, and thermal
evidence are captured; an `atexit` guard runs the same bounded command if the
profile aborts earlier. The JSON report records the command result, and a
requested cleanup failure makes the profiler exit nonzero.

Compare an A/B pair with explicit FPS and energy-per-visible-frame gates:

```bash
python3 misc/macws_compare_profiles.py \
  /tmp/baseline.json /tmp/candidate.json \
  --minimum-fps-gain-percent 0 \
  --maximum-energy-regression-percent 3 \
  --output /tmp/comparison.json
```

The comparison also reports producer FPS, delivery retention, every direct
pipeline latency distribution, and scheduler counters. Re-presenting a stale
IOSurface cannot improve the score: cadence counts only new producer sequences
that reached a real Host drawable presentation callback. A valid screenshot,
zero command errors, and a non-serious thermal state remain required witnesses.

Use two scene classes rather than mixing unlike runs:

- sustained animation: compare visible FPS, frame p95/p99/max, producer p99,
  empty-tick rate, power, and mJ per unique visible frame;
- static desktop: compare mean power and temperature, while requiring Host,
  WindowServer, and displayd IOSurface bytes to remain flat. Static FPS and
  energy/frame are intentionally not meaningful.

The first stable 1000-fish/1024-square run on the iPad13,6 M2 path measured
117.75 Host-visible FPS from 117.94 producer FPS, 99.79% delivery retention,
8.34 ms p50/p95 frame intervals, and 14.91 mJ per unique visible frame. The
same interval attributed 96.52% of one CPU core to the VSCode/Electron target
tree, 11.30% to MacWSHost, 3.10% to WindowServer, and 0.66% to macwsdisplayd.
These are runtime-confirmed by profile
`aquarium-1k-target-retire-v35`; the screenshot showed intact 1000-fish
output and the page's own 119 FPS counter.

A separate Host `vmmap` witness found eight retained 1822x1468 producer
IOSurfaces after repeated VSCode relaunches. The ownership root was the
per-owner `_frames`/`_pendingFrames` dictionaries surviving a target PID
change. `setTargetPID:` now retires those dictionaries and its scheduled
frame, while already-submitted frames remain fenced by their Metal completion
blocks. After two more VSCode relaunches the Host remained at the active
three-surface producer pool, and a 30-second interval reported zero Host,
WindowServer, and displayd IOSurface growth. This is the memory-stability
gate for future transport changes.

For an idle-platform control, the same Terminal scene was measured twice with
the still-visible Aquarium first running and then temporarily stopped. With
Aquarium running, its non-target GPU helper and renderer still consumed
62.40% and 32.65% of one CPU core and system power was 1256 mW even though the
Host direct scheduler correctly reported zero ticks. With that process tree
paused, system power fell to 94.35 mW (GPU 1.2 mW), temperature fell from
35.09 C to 35.00 C, MacWSHost used 0.23% of one core, and all measured
IOSurface deltas stayed zero. These runtime-confirmed profiles distinguish
real visible application work from an idle-platform regression instead of
misattributing all device heat to WindowServer or MacWSHost.

`--target-pid` is not restricted to known application names: the profiler
always captures the selected PID and its complete descendant tree in addition
to its standard MacWS/process roles. This matters for Terminal, native games,
and launchers whose executable names are not predictable in advance.

## Why CAPerfHUD alone is insufficient

CAPerfHUD commit `4a40c9253fc11a948fae57ec96d5d2c8dc028481`
(2026-05-01) calls these QuartzCore render-server functions:

```text
CARenderServerGetDebugFlags(0)
CARenderServerGetDebugValue(0, 1)
CARenderServerSetDebugValue(0, 1, level - 1)
CARenderServerSetDebugFlags(0, 0x10000000, flags)
```

That is useful for a system-wide FPS/GPU/glitch overlay, but it cannot identify
whether MacWS time was spent in SkyLight capture, IOSurface transfer, Host
submission, GPU execution, or final presentation. It also has no knowledge of
`MacWSInputRecord`, so it cannot measure input-to-visible latency.

`MacWSHost` therefore gained the same opt-in system HUD access (with
`com.apple.QuartzCore.debug`) plus its own profiler. The Apple HUD defaults to
off and is always forced off by the measured CLI run because it is global and
can perturb the screen being measured.

Apple's supported offline tools remain useful for a deep investigation:

- [Game Performance and Metal Instruments](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/)
- [Metal Performance HUD metrics](https://developer.apple.com/documentation/xcode/understanding-metal-performance-hud-metrics)
- [Animation Hitches](https://developer.apple.com/documentation/xcode/improving-app-responsiveness)

They are not the daily release gate because MacWS crosses an iOS Host, a
chrooted macOS WindowServer, AppKit processes, and a custom input broker.

## Measured pipeline

`MacWSPerformanceMonitor` writes allocation-free fixed rings (512 samples) on
the frame path. Sorting, percentile calculation, JSON encoding, and label
layout happen only at the explicit export or 2 Hz HUD update boundary.

```text
MacWS input dispatch
        │
        ▼
macOS AppKit/Dock ──► SkyLight CGDisplayStream captureTime
        │                         │
        │                         ▼
        │                Host receiptTime (IOSurface)
        │                         │
        │                         ▼
        │                Host Metal submitTime
        │                         │
        │                         ├──► MTLCommandBuffer GPUStart/GPUEnd
        │                         │
        └─────────────────────────┴──► CAMetalDrawable presented callback
```

The JSON reports:

- source frame interval;
- capture → Host receipt;
- Host receipt → Metal submit;
- submit → command completion;
- GPU execution time;
- capture → visible callback;
- Host input dispatch → first subsequently captured visible frame;
- real drawable frame intervals, hitch count, estimated missed vsyncs, command
  errors, and thermal state.

Two presentation cadences are kept deliberately separate:

- `frame_interval` / `active_average_fps`: drawable callbacks within 250 ms
  of real Host input, with gaps over 150 ms excluded. This is the touch
  fluidity metric.
- `observed_frame_interval`: autonomous producer cadence for workloads such as
  WebGL/video that animate without input.

This distinction prevents a static application's 10 Hz status refresh from
being mislabeled as interactive 10 FPS.

## User interface

MacWS Control Center now has a **Performance Measurement** section:

- Off / Compact / Full MacWS HUD;
- Apple system render HUD toggle;
- Reset measurement;
- Export JSON;
- Run standard touch/gesture regression.

The full HUD shows actual presentation FPS, 1% low, frame p99,
capture-to-visible, input-to-visible, GPU time, hitch/drop/error counts, thermal
state, and sample count. With the HUD off, ordinary production frames take one
atomic-boolean fast path and do not install Metal/drawable callbacks. Reset or
gesture replay starts explicit recording; export stops it. Hiding the HUD
during an explicit recording does not cancel that measurement.

Runtime postcondition on the final build: a cold HUD-off snapshot reported
`instrumentation_active=false` with every counter at zero. Reset plus one tap
reported 53 received / 51 presented frames and one input; after export, a
second tap followed by another snapshot retained exactly those counters and
reported `instrumentation_active=false`. Thus the off state does not quietly
keep Metal completion/presentation instrumentation alive.

Exports are written atomically to:

```text
/var/mobile/Library/Logs/MacWSPerformance/latest.json
/var/mobile/Library/Logs/MacWSPerformance/profile-YYYYMMDD-HHMMSS.json
```

Only the newest 20 archived profiles are retained.

## Gesture replay

The Host-integrated replay uses the same controller boundary as physical UIKit
input, so profiler input timestamps and fullscreen hit routing remain intact.
The suite covers:

- primary tap;
- double tap;
- secondary tap;
- pointer hover without a click;
- 120 Hz primary-button drag;
- long-press followed by a primary-button drag;
- 120 Hz phased scroll;
- phased scroll with a native momentum tail;
- 120 Hz phased magnify;
- 120 Hz native Dock vertical up/down gestures;
- 120 Hz native Dock horizontal left/right gestures.

System gestures stop at signed progress `±0.35` and send the native Cancel
phase. They exercise Dock's fluid animation without creating/removing Spaces
or leaving Mission Control active. This is a transport/rendering replay, not a
claim that UIKit recognizer arbitration before `MacWSInputRecord` has been
measured.

## One-command fixed-floor gate

Run from the controlling Mac:

```bash
python3 misc/macws_ui_profile.py \
  --host 192.168.1.6 \
  --output /tmp/macws-ui-profile.json
```

The runner:

1. aborts only at the project's configured `Critical` thermal state;
2. verifies the focused Host target and required process generations;
3. disables both overlays during measurement;
4. resets and exports one independent profile per gesture;
5. runs the InputLab semantic matrix and 60/120 Hz motion gates;
6. verifies process stability and thermal state; and
7. scores against fixed iPad floors, without requiring a MacBook run.

Current fixed floors are 60 FPS target, 55 FPS minimum average, 45 FPS 1% low,
input-to-visible p95 ≤ 50 ms, input bridge p95 ≤ 8 ms, zero Metal command
errors, ≥45 delivered moves/s for a 60 Hz stream, and ≥60 delivered moves/s
for a 120 Hz stress stream.

## 2026-08-12 13 ms production baseline

Runtime-confirmed on iPad13,6 at nominal 29.5 °C. All thirteen scenarios
completed; WindowServer `16770`, Dock `27704`, InputLab `26651`, displayd
`25930`, inputd `25928`, and Host `16845` retained the same PID before and
after the run. The semantic matrix passed and all Host-side Metal command
error counters were zero. The table uses the exact application source for
ordinary interactions and final drawable presentation for the native
multi-layer Dock animations.

| Scenario | Active avg FPS | 1% low | frame p50 / p95 / p99 ms | input→visible p95 ms | GPU p95 ms |
|---|---:|---:|---:|---:|---:|
| Hover | 52.34 | 36.18 | 17.63 / 24.66 / 27.64 | 41.10 | 2.64 |
| Drag | 50.41 | 36.07 | 17.59 / 26.71 / 27.72 | 45.22 | 2.51 |
| Long-press drag | 51.68 | 36.10 | 17.87 / 25.26 / 27.70 | 44.13 | 2.80 |
| Scroll | 49.72 | 34.64 | 17.89 / 28.45 / 28.87 | 44.92 | 2.53 |
| Momentum scroll | 51.66 | 35.96 | 17.77 / 26.80 / 27.81 | 41.01 | 2.67 |
| Magnify | 52.06 | 38.88 | 17.70 / 25.35 / 25.72 | 41.20 | 2.48 |
| Three-finger up | 88.96 | 8.89 | 8.34 / 20.84 / 112.55 | 47.19 | 3.25 |
| Three-finger down | 86.58 | 10.00 | 8.34 / 20.84 / 100.04 | 50.80 | 2.85 |
| Three-finger left | 32.59 | 12.63 | 33.35 / 58.36 / 79.20 | 66.33 | 2.44 |
| Three-finger right | 33.27 | 9.23 | 25.01 / 54.19 / 108.38 | 58.15 | 2.31 |

InputLab remained much faster than the visible boundary:

| Input stream | delivered rate | bridge p95 |
|---|---:|---:|
| requested 60 Hz | 59.78 events/s | 3.165 ms |
| requested 120 Hz | 113.56 events/s | 2.770 ms |

This is runtime evidence that the principal remaining UI problem is not the
AF_UNIX input broker or Host GPU execution. The broker preserves 94.7% of a
120 Hz stress stream below 3 ms p95, while ordinary content remains around
50–52 FPS and horizontal Space presentation around 33 FPS with only 2–3 ms
GPU p95. The next optimization boundary is therefore producer/presentation
cadence and exact SkyLight Space geometry, not another event-specific input
patch.

The runner also uses the inode of atomically replaced `latest.json` as its
generation witness. Seconds-resolution mtime plus byte size was runtime-
disproved: adjacent exports can share both values and previously caused a
false “no fresh performance JSON” failure after all thirteen gestures had
actually completed.

## 2026-08-12 active-cadence A/B

Reducing the production active completion interval from 13,000 us to 8,333 us
while retaining the 100,000 us idle interval improved the same full regression
at nominal 29.59 °C. Ordinary active averages moved from 49.72–52.34 FPS to
54.14–55.55 FPS; vertical native Dock animations moved from 86.58–88.96 FPS
to 96.52–99.09 FPS; horizontal Space animations moved from 32.59–33.27 FPS to
56.85–63.98 FPS. Drag passed the fixed release floor at 55.55 FPS average and
46.96 FPS 1% low.

This is not a blanket PASS. Horizontal presentation still has 108–125 ms p99
gaps, the right-Space gesture has 65.94 ms input-to-visible p95, and several
ordinary gestures remain below the 45 FPS 1%-low floor. The exact A/B records,
stable PIDs, thermal sample, and SkyLight transaction ABI evidence are in
[`ui-performance-regression-20260812.md`](ui-performance-regression-20260812.md).
