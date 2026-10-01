# Retina Standard unbounded window resize — 2026-10-01

Status: runtime-confirmed on `192.168.1.2`, iPadOS 16, Retina Standard
density. The production fix was installed as both arm64e and arm64
`libmachook` slices. No SpringBoard or WindowServer restart was required;
already-running applications must relaunch to map the new library.

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
`16384` transport sentinel. The initial implementation adapted the second
constraint only during the dynamic scope of one Host ConfigureWindow setter.
That was insufficient: AppKit can perform another frame-constraint pass after
the setter and its immediate `layoutIfNeeded` return.

An exact Scene now records a two-bit window-owned policy identifying only the
axes whose real application maximum is unbounded. Later native
`constrainFrameRect:toScreen:` passes restore the frame proposed by AppKit on
those axes when the original implementation reduces it to the virtual screen.
This does not pin the window to the previous Host size: a later application
request for a smaller frame remains smaller. A bounded window and every
transient popup keep native AppKit policy. An ordinary in-screen frame whose
origin alone is adjusted also keeps the native result.

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

## Delayed regression found after the first acceptance

The synchronous ACK above was not a sufficient stability witness. A fresh
VSCode PID 43044, window 683 published this exact ACK:

```text
requested=1308.0x825.5
applied=1308.0x826.0
maximum=16384.0x16384.0
```

The live CoreGraphics catalog later reported the same window as
`(0,25 1341x734)`, and Host recorded:

```text
1790850413.998 window-size follows-appkit window=683 pid=43044 reason=appkit-autonomous logical=1341.0x734.0 density=1.000 chrome=0.0x48.0 scene=1341.0x782.0 fixed=NOxNO requested=YES
```

Runtime A/B therefore confirms that the virtual-screen invariant was lost
after the synchronous setter scope, not in the application maximum or the
wire request. The window-owned policy above fixes that lifetime error rather
than retrying or forcing an old size.

After installing the persistent policy, fresh Terminal PID 59473, window 688
received `1330x815.5`. The live CoreGraphics catalog reported `1330x816` four
seconds later and again after Host completed its reverse Scene resize. Host's
corresponding stable observation was:

```text
1790851103.250 window-size follows-appkit window=688 pid=59473 reason=appkit-autonomous logical=1330.0x816.0 density=1.000 chrome=0.0x48.0 scene=1330.0x864.0 fixed=NOxNO requested=YES
```

A subsequent independent request for `1000x650` produced live bounds
`(194,25 1000x650)`. This confirms the persistent policy removes only the
screen upper-bound clamp; it does not pin the window to the earlier oversized
frame.

## Validation

- `macws_window_configuration_test`: unbounded/bounded classification,
  persistent exact-Scene axis policy, over-screen sizing, leading-edge
  anchoring, ordinary in-screen placement, and NaN fail-closed behavior pass
  under `-Wall -Wextra -Werror`.
- Full local suite: 606 tests passed, 13 skipped.
- Final delayed device snapshot: WindowServer 1.3% CPU and Terminal 0.0% CPU
  while the enlarged test surface was live; no web or graphics stress workload
  was used.
