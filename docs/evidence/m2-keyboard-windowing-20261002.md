# M2 7DTD keyboard latency and pre-Chamois Scene routing (2026-10-02)

Target: iPad14,5, iPadOS 16.0 / 20A8372, Ventura 13.4 / 22F66 chroot.

This note separates runtime-confirmed causes from the final acceptance still
required on the physical device. Process uptime and successful event enqueue
are not treated as proof of responsive gameplay.

## Platform and erroneous Split View reproduction

The target inventory is runtime-confirmed as:

```text
ProductVersion: 16.0
BuildVersion: 20A8372
hw.machine=iPad14,5
```

The user described the device as iOS 15, but the installed build is iPadOS
16.0. UIKit reports `supportsMultipleScenes=YES` on this build. A second macPad
Scene request nevertheless produced a `678x1024` Scene, the width of a Split
View column rather than an independent Stage Manager window. Therefore
`supportsMultipleScenes` is not a sufficient capability check.

The production rule is now:

- iPadOS earlier than 16.1 is explicitly non-Chamois, independent of tweak
  injection;
- on later systems SpringBoard's real
  `isChamoisWindowingUIEnabled` layout-calculator argument publishes the live
  `Known` / `Active` capability bits;
- only `Active` may create an additional UIKit Scene;
- inactive or not-yet-known state opens the requested AppKit window in the
  current macPad Scene and retires redundant iOS Scene containers without
  closing their AppKit windows;
- the delayed foreground-postcondition retry is gated a second time, both
  before scheduling and when its block fires, so a stale restored Scene cannot
  recreate a Split View column while single-Scene enforcement retires it.

This keeps iPadOS 16.0 from entering Split View while preserving independent
windowing on a live Stage Manager system. The compatibility witness on the M1
iPadOS 16.3.1 target is:

```text
1790883210.214 chamois-windowing-state known=YES active=YES source=frame-calculator
```

The corresponding iPadOS 16.0 `scene-activation reused-current` runtime line
and final visual acceptance remain pending until the target reconnects.

## Keyboard latency boundary measurements

The first physical-key route sent every hardware key through the OSXvnc /
WindowServer session proxy. Runtime timing showed that Bluetooth/UIKit,
broker routing and CG event creation were not the long pole:

```text
MACWS-INPUT KEYBOARD-LATENCY stage=broker sample=4001 kind=11 keycode=13 producer-to-broker=0.256ms broker-route=0.055ms sent=YES route=osxvnc-proxy
stage=session-proxy pid=8244 sample=4001 kind=11 keycode=13 producer-to-proxy=0.472ms proxy-post=3.100ms posted=YES
```

The 7DTD process's `-[NSApplication sendEvent:]` witness received none of
those global-session records. Sending the same exact-window record to the
process AppInput socket did reach AppKit, but its ordinary event queue was
drained in roughly one-second batches:

```text
stage=app-dispatch pid=7996 kind=down keycode=13 producer-to-app=1002.915ms
stage=app-dispatch pid=7996 kind=up keycode=13 producer-to-app=803.793ms
```

After moving exact-window hardware records to AppInput, a clean arm64 Unity
player generation (`pid=13428`, AppKit window `38`) confirmed the transport
itself was fast while Unity's Cocoa event pump remained slow:

```text
stage=app-socket pid=13428 sample=7001 producer-to-socket=4.942ms
stage=app-queue pid=13428 sample=7001 producer-to-queue=5.726ms delivery=post-event
stage=app-dispatch pid=13428 kind=down keycode=13 producer-to-app=997.732ms
```

Later steady-state socket/queue records were generally `0.15-1.11ms`, while
dispatches still arrived in approximately `81-997ms` batches. This
runtime-confirms that the perceived delay was not Bluetooth transport or the
macPad broker; it was the mismatch between ordinary
`-[NSApplication postEvent:atStart:]` enqueue and Unity 2022.3.62f2's Cocoa
event-pump cadence.

## Root-cause route under acceptance

For only the exact 7DTD physical-key route, the current candidate calls
`CGPostKeyboardEvent` from the already-CGS-connected game process. The THEORY
is that this wakes the event source on which Unity's `nextEvent` path waits; a
zero CoreGraphics return is explicitly not treated as delivery proof. A
nonzero status falls back to the ordinary AppKit queue. Software text,
Terminal/VS Code shortcuts, on-screen toolbar input, and global/fullscreen
hardware routing retain their existing paths.

An earlier candidate binary was installed before the device went offline, but
the final correlated-sample and non-printable-key refinement still requires a
fresh deployment and game restart. Required acceptance is therefore explicit:

1. `stage=app-cgs-post ... status=0` followed promptly by
   `stage=app-dispatch ... route=cgs-correlated` for the same nonzero physical
   sample ID (the diagnostic FIFO expires unmatched posts after two seconds);
2. repeated W/A/S/D movement without batching;
3. Shift-down, Shift+W and Shift-up with correct release and no crash/hang;
4. bounded game run, nominal starting temperature, and teardown of Steam,
   game, diagnostics and GUI services afterward.

Until all four are observed, this route is an evidence-backed candidate, not
a claimed final latency fix.
