# 7 Days to Die M2 fullscreen, Shift, and audio evidence (2026-09-29)

Target: iPad14,5, iPadOS 16.0, Steam app 251570, native arm64 Unity
2022.3.62f2 player. All runtime observations below were made against the
installed production package unless a diagnostic generation is explicitly
identified.

## Shift freeze root cause and repair

The first failing generation was sampled before changing the code. All 1,345
main-thread samples stopped below the window-metrics timer:

```text
MacWSPublishWindowMetrics +1384
-[NSWindow(NSWindowTabbing) _tabGroup]
-[NSWindowStackController setupStackControllerForWindow:]
-[NSWindow tabBarItem]
+[NSImage imageNamed:]
IconServices ... synchronous XPC wait
```

This is runtime-confirmed via the PID 99974 `sample` capture. The metrics
publisher was treating the public `tabGroup` property as a read-only query,
but AppKit created a tab stack and synchronously requested its icon. Every key
event schedules a metrics publication, so moving while holding Shift
re-entered this blocked main-thread path.

`misc/appkit_window_tab_probe.m` inventories the methods from the actual
Ventura 13.4 AppKit image and can exercise them in the chroot. The target probe
returned immediately for a plain `NSWindow`:

```text
exercise-before selector=_windowStackController responds=1
exercise-after selector=_windowStackController object=0x0 class=<nil>
```

The production publisher now reads `_windowStackController` and only walks
the existing controller's `windows` collection. It does not ask AppKit to
create a tab group. This preserves the logical identity of real tabbed windows
instead of bypassing tab handling.

After installation, PID 9780 received 24 production Shift+W/A/S/D presses
(48 key records, 200 ms holds) and remained live. A subsequent two-second
sample contained no `_tabGroup`, `CGSEventSourceShutdown`, or IconServices
wait stack. One sampled metrics invocation was actively constructing the
fullscreen bundle-identifier string and returned; it was not stuck.

## Exact fullscreen ownership and presentation cadence

The native player publishes `com.The-Fun-Pimps.7-Days-To-Die`. It now marks
its real game window as a fullscreen-canvas-capable direct-drawable source.
The Host also retains an explicit PID/window request for up to ten seconds
while a cold Scene waits for its first authoritative window catalog. It does
not fall back to a Steam Helper from a stale catalog.

Production log for PID 9780/window 89:

```text
fullscreen-canvas-capability pid=9780 window=89 source=controller-validated-catalog canvas=2732x2048
direct-drawable-heartbeat pid=9780 layer=89 drawable=1366x1024 canvas=2732x2048 identity=retained-live-fullscreen-canvas
performance-profile-target pid=9780 window=0 mode=1 requested=9780 previous=9780
```

The 10.11-second production profile reported:

```text
owner_pid                              9780
unique_frames_received                 1194
host_unique_frames_presented           1176
missing_sequences                      0
host_visible_average_fps               116.65170684355168
host_visible_one_percent_low_fps        59.963871785341105
host_visible_interval_p95_ms             8.338458341313526
completion_to_host_receipt_p95_ms        0.7048333333333334
gpu_execution_p95_ms                     2.2250000038184226
thermal_state                           nominal
command_errors                          0
input_transport_errors                  0
```

This is a **startup-screen transport measurement**, not an in-world gameplay
benchmark. It proves that the 10 FPS desktop composite is no longer the game
presentation path and that unique Unity drawables reach a real Host
presentation callback without sequence loss. It does not establish physical
finger-to-world latency or an in-game M2 MacBook-equivalent FPS.

The same production generation then survived the 24-key Shift movement stress
and reported 1,223 unique Host-presented frames in 10.49 seconds (116.50 FPS,
59.96 FPS 1% low, no missing sequence).

## Audio bridge

During the production game process, the shared ring header changed over a
two-second observation:

```text
writeFrame     0x125929c00 -> 0x125942200  (+99,840 frames)
callbackCount  0x91d4cc    -> 0x91d58f     (+195 callbacks)
ownerToken     0x0000263400000001           (PID 0x2634 = 9780)
```

The native output daemon simultaneously logged:

```text
macwsaudiooutd: ring connected rate=48000 channels=2
macwsaudiooutd: output start status=0 preroll=4800
macwsaudiooutd: runtime-confirmed hardware callback count=12 read-frame=4917675072
```

This runtime-confirms that the game owns the PCM ring, publishes at roughly
48 kHz, and that the native AudioQueue callback consumes it. It validates the
software-to-hardware callback path; physical audibility was not measured by a
microphone in this run.
