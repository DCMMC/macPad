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

## Consecutive Steam generations and duplicate-player load

The final package exposed a separate lifecycle defect after the initial
stress run. Two consecutive Steam clients were started with `-applaunch
251570`. The first client exited without stopping its checked-in game, then
the replacement Steam client launched the same signed runtime again. The
runtime process inventory was:

```text
30667     1 ... 62.0% .../7DaysToDie-ARM.app/.../7 Days To Die -from-steam
31118 30695 ... 59.3% .../7DaysToDie-ARM.app/.../7 Days To Die -from-steam
```

The Host independently received completed 1366x1024 direct drawables from
both PID 30667/layer 41 and PID 31118/layer 78. `lsappinfo` and the AppKit
window catalog showed PID 30667 as the foreground, onscreen instance; its
audio-ring owner token was also `0x77cb` (30667). PID 31118 was offscreen but
still consumed a comparable CPU share and submitted frames. This is
runtime-confirmed by `/var/mobile/Library/Logs/MacWSHost.log`,
`/var/jb/var/mobile/steam-runtime.log`, `ps`, and `lsappinfo` on the target.

The signed-runtime fallback now restores LaunchServices' normal
single-instance invariant at the correct upstream layer. Before launching the
exact 7DTD arm64 runtime, it asks `NSRunningApplication` for the bundle's
already checked-in applications, verifies the exact executable path, live PID,
and non-terminated state, then returns that real application object to Steam.
It neither fabricates launch success nor kills/replaces a valid game. The
manually observed duplicate PID 31118 was retired after recording the above
witnesses; PID 30667 remained live, onscreen, and the only 7DTD producer.

The rebuilt package was then installed and a fresh Steam generation was
started while PID 30667 remained checked in. Fresh Steam PID 35659 emitted:

```text
[MacWSSteamProcess] existing 7DTD runtime reused pid=30667 executable=/Users/root/Library/Application Support/Steam/steamapps/macws-runtime/7 Days To Die/7DaysToDie-ARM.app/Contents/MacOS/7 Days To Die
Game process added ... ProcID 30667
```

The post-launch process inventory contained exactly one matching arm64 game
runtime (PID 30667). This runtime-confirms that the installed implementation
prevents a replacement Steam generation from creating the duplicate player
that had been consuming CPU and submitting invisible frames.

## Fullscreen direct-drawable input visibility

The first fullscreen input profile incorrectly correlated the synthetic tap
with Dock PID 29743, even though runtime logs identified PID 30667/window 41
as the controller-validated fullscreen direct-drawable authority. A diagnostic
snapshot made the mismatch explicit while the game continued to submit:

```text
direct_target_unique_submissions=1395
inputs_attempted=24 inputs_sent=24
pending_input_target_pid=29743 input_visibility_pending=true
direct_input_visibility_samples=0
composited_input_visibility_samples=0
```

The Host now keeps Dock as the global pointer transport endpoint but uses the
resolved visual game PID for performance correlation whenever the renderer's
existing `authoritativeFullscreenDrawableFrame` invariant is satisfied. It
also prevents hidden DisplayStream layers from claiming an input sample while
that direct drawable is authoritative. This does not bypass input delivery or
fabricate a response: a sample is recorded only when a producer-completed,
monotonically newer game sequence reaches the real Host CAMetalDrawable
presentation callback.

After installing package SHA-256
`d481d1cb506294bd89984b489e9d4a363d469f7a5af05dc2ea2b4cbffe634973`,
a 24-click, 10 Hz pressure run produced 24 direct samples, zero composited
samples, and zero transport errors. Its median was 24.86 ms and p95 was
116.47 ms, showing that the burst still has a long tail. A second profile of
five individually spaced taps produced:

```text
direct_input_visibility_samples=5
composited_input_claims=0
input_transport_errors=0
input dispatch -> visible: mean=23.40 ms p50=23.38 ms p95=27.61 ms max=27.61 ms
game direct visible: 114.12 FPS, 1% low=59.96 FPS, missing_sequences=0
thermal_state=nominal
```

These figures are runtime-confirmed by
`/var/mobile/Library/Logs/MacWSPerformance/latest.json`. They measure a
synthetic Host-dispatch-to-present path on the animated title screen, not
physical finger latency and not in-world gameplay FPS. The 10 Hz pressure-run
tail remains visible rather than being averaged away.
