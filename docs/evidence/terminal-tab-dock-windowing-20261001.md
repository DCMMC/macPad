# Terminal tab handoff and floating-Dock avoidance (2026-10-01)

Target: iPad13,6, iPadOS 16.3.1 (20D67), `com.macwsguide.host`.

This note distinguishes source-contract checks from runtime witnesses. A
running process alone is not treated as visual or behavioral acceptance.

## Terminal tab handoff

The Host now retains the last frame only when a stream identity change keeps
both the previous owner PID and the nonzero AppKit logical window-group ID.
Cross-window and cross-process changes still call the real `suspendStream`
path.

Runtime-confirmed via `/var/mobile/Library/Logs/MacWSHost.log`:

```text
1790867692.933 window-identity-follow owner=63559 group=880 old=880 new=881 frame-preserved=YES
1790867693.784 window-identity-follow owner=63559 group=880 old=881 new=880 frame-preserved=YES
```

The user subsequently confirmed that the Terminal tab-switch flash was fixed.

## Why the first Dock fix was rejected

SpringBoard's stock frame calculation received a 114.5-point floating-Dock
exclusion, but a Host frame using the dense exact-size grid still extended
through it. An initial returned-frame correction was later opposed by the
fixed exact-size model:

```text
1790867829.566 dense-grid-result ... proposed=1308.0x847.5 constrained=1308.0x847.5 result=1308.0x847.5 ...
1790867829.566 item-layout-dock-avoidance ... original={{40.5,24},{1308,847.5}} result={{40,24},{1309,832}}
1790867829.567 resize-policy springback ... proposed=1309.0x832.0 constrained=1308.0x847.5 result=1308.0x847.5 fixed=YESxYES
```

A later upstream maximum-height candidate stopped the overlap, but also
stopped the user's resize gesture from growing the window. It was removed.
After removal, the authoritative model grew past that rejected ceiling and
remained exact:

```text
1790869046.807 dense-grid-result grid=0x2825a5b00 proposed=1134.0x824.0 constrained=1134.0x824.0 result=1134.0x824.0 candidates=128x83 stock=8x4 policy=sceneID:com.macwsguide.host-1B2C644F-EC23-4639-91AE-61BC4F6AC966
```

The production rule is therefore: never alter the authoritative Host size or
publish a Dock-derived maximum height. Translate an unchanged frame when it
fits; when it cannot fit, ask the native floating Dock to yield.

## Native floating-Dock control path

Runtime Objective-C metadata on this exact SpringBoard established these
available APIs:

- `SBFloatingDockController`
  `dismissFloatingDockIfPresentedAnimated:completionHandler:` with encoding
  `v28@0:8B16@?20`.
- `SBFloatingDockController -activeAssertion`.
- `SBFloatingDockBehaviorAssertion`
  `initWithFloatingDockController:visibleProgress:animated:gesturePossible:atLevel:reason:withCompletion:`
  with encoding `@64@0:8@16d24B32B36Q40@48@?56`.
- `SBFloatingDockBehaviorAssertion -invalidateWithCompletion:` and
  `-invalidate`.

Runtime-confirmed controller resolution from the live
`SBFloatingDockWindow`:

```text
1790868919.484 dock-runtime-object controller=YES class=SBFloatingDockController presented=YES
```

One-shot dismissal was not sufficient. Its completion still reported
`presented=YES`, and the live active assertion described itself as the pinned
homescreen owner with visible progress 1.0. The retained native assertion
path instead produced:

```text
1790869668.821 dock-yield-state scene=sceneID:com.macwsguide.host-1B2C644F-EC23-4639-91AE-61BC4F6AC966 active-class=SBFloatingDockBehaviorAssertion active-level=0 active-progress=1.000 active=<SBFloatingDockBehaviorAssertion: 0x2802a35c0> {
1790869668.822 dock-yield-request scene=sceneID:com.macwsguide.host-1B2C644F-EC23-4639-91AE-61BC4F6AC966 frame={{127.5, 73}, {1134, 824}} controller=SBFloatingDockController route=native-behavior-assertion level=1
1790869669.515 dock-yield-assertion-ready scene=sceneID:com.macwsguide.host-1B2C644F-EC23-4639-91AE-61BC4F6AC966 level=1 presented=NO
```

This is a native behavior assertion, not a hidden `UIWindow`, forced return
value, or validation bypass. It is retained only while the exact Host Scene
cannot fit above the remembered native Dock exclusion. It is invalidated when
the window becomes small enough, the container geometry changes, the Scene
leaves the current Stage Manager group, or the Host enters its macPad
fullscreen workspace.

The deployment build passed the arm64e constant-object check with 220
authenticated `__cfstring` binds and zero plain binds. SpringBoard stayed
alive after activation. The automated full-screen capture helper returned an
all-black surface after the respring, so this run does not claim a new
screenshot witness; the native controller's `presented=NO`
completion and the unchanged `1134x824` model are the runtime witnesses.

## Follow-up: stock Files parity (2026-10-02)

The first retained-assertion policy still required the complete native
`screenEdgePadding` above the Dock before considering a Host frame able to
coexist. A full iPadOS capture showed Files and the Dock coexisting, then a
diagnostic-only same-calculator witness measured the stock Files geometry
without inferring it from pixels:

```text
1790870982.200 item-layout-stock-witness bundle=com.apple.DocumentsApp scene=sceneID:com.apple.DocumentsApp-191BD95C-D57F-4DAE-BA5B-98C735C3D5E8 role=1 frame={{106, 24.5}, {1177, 807}} dock-height=114.5 container={{0, 0}, {1389, 970}} edge-padding=24.0 scale=2.0 prefers-dock-hidden=NO skip=YES
```

The comparable Host case was `1134x824`. With `dockTop=970-114.5=855.5`
and the 24-point top boundary, it still has 7.5 points between its bottom and
the Dock. Requiring another full 24 points therefore hid the Dock 16.5 points
too early.

The corrected policy preserves the native 24-point gap when it fits, then
allows only that empty gap to contract to a floor of eight physical pixels
(4 points at this screen's 2x scale). At `824` points high it chooses the full
available 7.5-point gap and translates the unchanged frame to `y=24`; it does
not resize the Scene. At heights where fewer than eight physical pixels
remain, the retained native Dock assertion still provides collision-free
behavior. The temporary all-item geometry logger was removed after collecting
the witness.

## Regression contracts

`misc/test_terminal_tab_dock_contract.py` enforces that:

- same-owner/same-group tab handoff preserves the predecessor frame;
- cross-window paths retain real stream suspension;
- Dock avoidance never mutates `frame.size` or the Scene size policy;
- the native assertion has balanced retention/invalidation;
- full-screen workspace entry and current-stage departure release it.
