# Retina Standard unbounded window resize — 2026-10-01

Status: runtime-confirmed on `192.168.1.2`, iPadOS 16, Retina Standard
density. The production fix was installed as both arm64e and arm64
`libmachook` slices. No SpringBoard or WindowServer restart was required.

## Before

Terminal PID 34068, CGWindow 633 published a real resizable AppKit window with
minimum `230x176` and maximum `16384x16384`. The latter is the window-metrics
transport ceiling and therefore means there is no application-authored upper
bound reachable by an iPad Scene.

The identified configure acknowledgement was:

```text
sequence=234
requested=1341.0x815.5
applied=1194.0x728.0
maximum=16384.0x16384.0
```

The width matched Retina Standard's virtual `NSScreen` width exactly instead
of the application's published maximum.

## Root cause and fix

There were two separate virtual-screen constraints in the real transaction:

1. `AppInputBridge` pre-clamped every anchored Host request to `NSScreen`.
2. Ventura AppKit's real `-[NSWindow constrainFrameRect:toScreen:]`, reached
   synchronously from `setFrame:display:animate:`, applied another screen
   placement constraint after the bridge had already applied the application's
   minimum, maximum, aspect ratio, resize increments and
   `windowWillResize:toSize:` result.

The first clamp now distinguishes a true application maximum from the
`16384` transport sentinel. The second is adapted only during the dynamic
scope of that one Host ConfigureWindow setter and only for unbounded axes. A
bounded window, a normal AppKit resize, and every transient popup keep native
AppKit policy. An ordinary in-screen frame whose origin alone is adjusted also
keeps the native result.

For an oversized top-right request, the leading title-bar edge stays at the
screen origin instead of using a negative x coordinate. Exact-window capture
continues to represent the complete surface.

## After

A fresh Terminal PID 39994, CGWindow 672 first accepted the ordinary in-screen
request `890x613` as `890x613`; the screen-constraint restoration log count was
zero. The same exact input endpoint then received sequence 7003 requesting
`1341x815.5` and published:

```text
maximum=16384.0x16384.0
requested=1341.0x815.5
applied=1341.0x816.0
```

The half-point height rounded through AppKit to one physical point; the width
is exact and is 147 logical points larger than the 1194-point virtual screen.
The runtime line copied from the target process proves the native screen layer
was the remaining constraint and that the transaction restored the already
application-constrained frame:

```text
#### APP-INPUT CONFIGURE-SCREEN-CONSTRAINT pid=39994 window=672 requested=(0.0,18.5 1341.0x815.5) screen=(0.0,78.0 1341.0x728.0) restored=(0.0,18.5 1341.0x815.5) unbounded=YES x YES
```

This production witness is emitted at most once per application process unless
runtime diagnostics are explicitly enabled, so dragging above the old boundary
does not create a per-frame logging or power cost.

The final rate-limited installed artifact was reloaded in fresh Terminal PID
41213. Two consecutive oversized requests ended at sequence 7005 with
`1330x815.5 -> 1330x816`, while the process log contained exactly one
`CONFIGURE-SCREEN-CONSTRAINT` witness.

## Validation

- `macws_window_configuration_test`: unbounded/bounded classification,
  over-screen sizing, leading-edge anchoring, ordinary in-screen placement,
  and NaN fail-closed behavior pass under `-Wall -Wextra -Werror`.
- Full local suite: 606 tests passed, 13 skipped.
- Final device snapshot: WindowServer 3.2% CPU, MacWSHost 0.2% CPU while the
  enlarged test surface was live; no web or graphics stress workload was used.
