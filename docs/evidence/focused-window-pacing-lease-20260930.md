# Focused-window direct pacing lease — 2026-09-30

Device: iPad13,6, iOS 16.3.1, 120 Hz panel. Workload: VS Code's
Chromium window showing the same continuously animating TestUFO page. Both
measurements used authenticated direct drawable transport, suspended the
redundant exact-window `CGDisplayStream`, and reported zero missing producer
sequences and zero Metal command errors.

The only display-path change between the two measurements was restoring the
validated direct-drawable pacing lease for window mode. The lease returns the
otherwise redundant WindowServer virtual-display completion loop to its
100-ms desktop cadence. MacWSHost's iOS `MTKView` panel scheduler remains at
120 Hz.

| Metric | Without window lease | With window lease |
|---|---:|---:|
| WindowServer interval CPU | 38.08% | 6.41% |
| macwsdisplayd interval CPU | 1.92% | 0.30% |
| MacWSHost interval CPU | 7.96% | 7.79% |
| Target Chromium process-tree CPU | 96.77% | 83.90% |
| Producer delivered cadence | 109.99 fps | 117.84 fps |
| Host-visible cadence | 107.31 fps | 117.83 fps |
| Host scheduler cadence | 119.71 Hz | 119.73 Hz |
| Empty Host scheduler ticks | 10.37% | 1.60% |
| Direct frames received / presented | 2648 / 2581 | 3388 / 3386 |
| Content frames received | 0 | 0 |
| Missing sequences / command errors | 0 / 0 | 0 / 0 |

Verbatim profiler summaries for the corrected run:

```text
"average_fps": 117.8293689469949
"scheduler_tick_hz": 119.72640863867595
"scheduler_empty_percent": 1.5974440894568689
"producer_delivered_fps": 117.84111750085142
"delivery_retention_percent": 99.9409681227863
```

```text
"window_server": { "average_cpu_percent": 6.408416025529695 }
"displayd": { "average_cpu_percent": 0.2957730473321398 }
"macws_host": { "average_cpu_percent": 7.788690246413014 }
"target_tree": { "average_cpu_percent": 83.90095442655033 }
```

The two package-power readings are deliberately not used for the A/B power
claim: the no-lease run began at thermal state `serious`, while the corrected
run began at `nominal` and entered `fair`, so DVFS operating points were not
comparable. The interval CPU and presentation counters remain directly useful
for locating the removed scheduling work. A cold, non-charging package-power
run is still required.

Raw local profiler artifacts and SHA-256 hashes:

- `/tmp/macws-testufo-window-direct-no-duplicate-charging-serious-v1.json` —
  `9c7788efe0974250127ab263818831189b6b41a3166be7557d3b36440f75e429`
- `/tmp/macws-testufo-window-direct-pacing-lease-charging-v2.json` —
  `d8c250499a9758ed713fbeceb5180ec3a3578a5061a67cb40c3154d0de4a1e0f`
- The earlier cold validated-window witness,
  `/tmp/macws-aquarium-1k-single-frame-fastpath-repeat-v37.json` —
  `3a52dfc46313217073161cbdbe4e9064d522c5b9c04b561bb7440dd341d5148c`
  (`117.91` producer fps and `3.11%` WindowServer CPU).
