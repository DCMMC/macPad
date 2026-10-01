# VSCode touch-scroll regression: synchronous global hit test

Date: 2026-10-01  
Device: `root@192.168.1.2:2222`  
Target before/after: VSCode PID 23141/window 623, then PID 25862/window 628  
Thermal state: nominal, 32.79–34.19 °C during bounded tests

## Symptom

VSCode's Markdown preview visibly lagged during direct-touch scrolling while
Terminal, Finder, and Activity Monitor remained responsive. Video and TestUFO
cadence were already healthy, so this run isolated the input-to-render path.

## Before-change runtime evidence

The repeatable `scroll` scenario sent 122 records over a nominal 120 Hz
gesture. The target produced only 31 unique direct drawables:

```text
owner_pid=23141 unique_frames_received=31
producer_delivered_average_fps=15.90070258579434
producer_frame_interval p50=21.517916666666668 ms
producer_frame_interval p95=203.4445 ms
producer_frame_interval max=512.3792083333333 ms
```

The target's own latency aggregate showed both severe main-thread work and
backpressure:

```text
#### APP-INPUT LATENCY pid=23141 kind=14 samples=29 seq=518..639 transport-us(avg/max)=7789.4/105763.0 queue-us(avg/max)=7333.1/102445.7 dispatch-us(avg/max)=34879.7/102661.7
```

A 3-second `/usr/bin/sample` of the actual Electron process located the
blocking operation. Across the two input-drain slices, 664 of 2087 main-thread
samples were in the same synchronous global hit-test path (523 + 141); 661 of
those were blocked at the SkyLight IPC leaf (520 + 141):

```text
523 MacWSPostInputOnMainThread (in libmachook_arm64.dylib) + 13360
  523 +[NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:]
    520 SLSCopyWindowRoutingRecordsForScreenLocation (in SkyLight) + 172
      520 mach_msg_new -> mach_msg -> mach_msg_overwrite -> mach_msg2_trap

141 MacWSPostInputOnMainThread (in libmachook_arm64.dylib) + 13360
  141 +[NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:]
    141 SLSCopyWindowRoutingRecordsForScreenLocation (in SkyLight) + 172
```

In that same sample, `_latchViewForScrollEvent:` and `sendEvent:` each
accounted for only one sample. This runtime evidence rejects the initial latch
overhead theory and confirms the repeated WindowServer hit test as the major
stall.

## Root cause and fix

`MacWSPostInputOnMainThread` queried
`+[NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:]` for every input
record. That global identity is required when admitting a new native system
pointer stream, and once when admitting a native system-scroll transaction.
Electron and Catalyst precise scrolls stay process-local; later phases of an
already admitted native scroll also retain their original target. None of
those phases consume a new global hit result.

The fix computes the route first and performs the synchronous global hit only
for an exact pointer start or a non-VNC native `ScrollBegan`. The Begin-time
exact-window equality remains intact, so covered-window/menu protection is not
weakened. No validation result is forged and no application-specific selector
is bypassed.

## After-change runtime evidence

The same VSCode document and same `scroll` scenario after deploying the new
arm64/arm64e libmachook produced 117–123 unique drawables. A warm run reported:

```text
owner_pid=25862 unique_frames_received=117
producer_frame_interval p50=8.602375 ms
producer_frame_interval p95=22.278916666666667 ms
host_visible_frame_interval p50=8.336875005625188 ms
input_dispatch_to_visible p95=37.216625 ms
```

The profiler's raw average includes its deliberate 500 ms post-gesture settle
gap, so it is not an active-scroll FPS value. The 8.34–8.60 ms median interval
is the relevant 120 Hz cadence witness during motion.

The target latency aggregate improved to:

```text
#### APP-INPUT LATENCY pid=25862 kind=14 samples=114 seq=2..123 transport-us(avg/max)=365.6/4416.0 queue-us(avg/max)=97.0/623.5 dispatch-us(avg/max)=444.6/1280.7
```

The matching after-change sample contained one
`SLSCopyWindowRoutingRecordsForScreenLocation` sample instead of 664. A
separate momentum run processed 114 records and remained sub-millisecond on
average inside AppKit dispatch:

```text
#### APP-INPUT LATENCY pid=25862 kind=14 samples=114 seq=3197..3318 transport-us(avg/max)=457.2/6435.0 queue-us(avg/max)=100.8/1034.0 dispatch-us(avg/max)=374.5/850.9
```

The retained rendered screenshot showed the Markdown preview scrolled to new
content with correct geometry and no visual corruption. The device remained
in nominal thermal state after the gesture and sampling runs.

## Scope

The change is route-based, not bundle-ID based. It removes redundant per-frame
global hits for all Electron/Catalyst process-local precise scrolls and for
continuation phases of native AppKit system scrolling. Pointer starts, native
scroll Begin, menu ownership, and covered-window exact-ID checks keep their
existing validation boundaries.

