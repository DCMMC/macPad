# VSCode window Scene drawable ownership (2026-10-01)

## Scope

This record covers VSCode Simple Browser in macPad's per-window iPadOS Scene,
using TestUFO and a foreground YouTube 4K60 video on iPad13,6. It does not use
a frame cap, an assertion bypass, or an application-name special case.

## Root cause

Runtime-confirmed before the fix:

- the visible replacement Scene was `mode=2 window=497`;
- the replaced fullscreen Scene logged `scene-disconnect preserved` but did
  not suspend its stream;
- displayd continued validating owner `63374`, layer `497` as
  `mode=fullscreen-layer` after that disconnect; and
- the visible window's performance monitor received zero direct frames while
  its exact-window fallback advanced at about 101 ms per frame.

`MacWSCatalystDrawableReceiver` broadcasts each producer delivery within the
process, but that delivery owns exactly one transferred IOSurface use count.
`MacWSCatalystDrawableCompositor` therefore lets only the first eligible Scene
claim it. The disconnected controller still had
`_acceptsCatalystDrawables=YES`, so it consumed the visible replacement's
frames and refreshed the wrong fullscreen direct-drawable lease.

The fix separates two lifetimes in `sceneDidDisconnect:`: it immediately calls
`suspendSceneStream` to relinquish presentation resources, while the existing
preservation transaction still keeps the AppKit window alive for the
replacement Scene.

## Runtime acceptance

The no-restart window -> fullscreen -> window regression logged:

```text
runtime-confirmed scene-disconnect stream-suspended id=3549F8B7-... window=0
runtime-confirmed catalyst-drawable imported owner=63374 producer=63383 ...
runtime-confirmed catalyst-drawable presented pid=63374 ...
```

displayd then changed the same owner/layer from `mode=fullscreen-layer` to
`mode=window-base`.

Two window-mode TestUFO profiles measured:

| Profile | Host-visible FPS | Scheduler | Received / presented | Retention |
|---|---:|---:|---:|---:|
| clean restart | 117.86 | 119.84 Hz | 2763 / 2760 | 99.89% |
| after live fullscreen round trip | 117.66 | 119.52 Hz | 2165 / 2156 | 99.58% |

The browser's own 10-second `requestAnimationFrame` witness measured 118.02
FPS, 8.40 ms p50, 9.28 ms p95, and one interval over 20 ms.

For YouTube, `HTMLVideoElement.getVideoPlaybackQuality()` on the foreground
3840x2160 source measured 904 decoded frames over 15.08 seconds (59.96 FPS).
The matching foreground window profile measured 59.17 Host-visible FPS,
879 direct frames received, 878 presented, 99.89% retention, and a 119.89-Hz
panel scheduler. A prior 9.86-FPS sample was explicitly rejected as a
foreground-video result: Terminal was the application-key Scene during that
interval. The profiler now routes both reset and snapshot URLs to the visible
Scene whose persisted `owner_pid` matches the requested target, preventing a
different macPad window from producing a false zero/low-FPS report.

Power/thermal witnesses remained bounded during the scored runs:

- TestUFO clean restart: 4.56 W mean, 36.19 -> 36.39 C;
- TestUFO live round trip: 4.43 W mean, 37.00 -> 37.29 C;
- foreground YouTube: 4.19 W mean, 37.00 -> 37.19 C;
- every run reported zero command errors.

The test page was closed after validation.
