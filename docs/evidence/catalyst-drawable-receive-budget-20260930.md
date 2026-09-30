# Catalyst drawable bounded receive budget — 2026-09-30

Device: iPad13,6, iOS 16.3.1. Workload: VS Code Simple Browser running the
1000-fish, 1024×1024 WebGL Aquarium through the focused-window direct path.
Both runs used the validated direct-window pacing lease, had no content-stream
frames, and reported zero Metal command errors.

The process-global Mach receive source and `MTKView` display link both execute
on UIKit's main queue. An unlimited receive drain previously starved display
ticks. Restricting the source to exactly one message per invocation fixed that
starvation, but left no bounded catch-up capacity after an input-heavy main
queue interval. The second run consumes at most two messages per source
invocation and must yield before a third; the producer owns a three-IOSurface
pool.

| Metric | One message/callback | Two messages/callback |
|---|---:|---:|
| Measurement elapsed | 42.23 s | 38.91 s |
| Host input attempts | 215 | 961 |
| Direct frames received | 4844 | 4581 |
| Missing producer sequences | 51 | 0 |
| Completion → Host receipt p50 | 0.179 ms | 0.175 ms |
| Completion → Host receipt p95 | 3.169 ms | 0.294 ms |
| Producer delivered cadence | 114.72 fps | 117.74 fps |
| Host-visible cadence | 114.08 fps | 117.74 fps |
| Host scheduler cadence | 117.87 Hz | 119.92 Hz |
| Empty scheduler ticks | 3.21% | 1.86% |
| Delivery retention | 99.42% | 99.91% |
| Command errors | 0 | 0 |

Verbatim corrected-run excerpts:

```text
"inputs_attempted": 961
"direct_drawable_frames_received": 4581
"direct_drawable_unique_frames_presented": 4577
"missing_sequences": 0
"producer_delivered_average_fps": 117.74100072256148
"host_visible_average_fps": 117.73785506830903
```

```text
"completion_to_host_receipt": {
  "p50_ms": 0.17520833333333335,
  "p95_ms": 0.2944583333333333
}
"scheduler_tick_hz": 119.91557003254653
"scheduler_empty_percent": 1.86455207886841
```

The runs intentionally differ in input count, so their package-power values
are not used as an A/B power claim. The corrected run is the stricter receive
stress case: it handled more than four times as many input attempts while
eliminating the sequence gaps and improving both producer and panel cadence.

Raw local profiler artifacts and SHA-256 hashes:

- `/tmp/macws-aquarium-1k-window-direct-pacing-lease-no-charge-v3.json` —
  `005a0f80e8a9cf06106a2b8d228ace76906fc4282228b5c33540fc4598f434d3`
- `/tmp/macws-aquarium-1k-receive-budget2-hover-no-charge-v4.json` —
  `cfdb682de033555f5166a952785babc6e0876e46569e206f410062de3403e68b`
