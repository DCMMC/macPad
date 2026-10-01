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

## Follow-up: returned frame was not the authoritative position

The adaptive-gap calculation above was correct, but the first implementation
applied it only to the return value of
`_frameForLayoutRole:inAppLayout:...`. A full iPadOS capture retained locally
as `/tmp/dock-problem-current.png` showed the live `1171x817` Host window still
centered at approximately `y=76.5` and visibly underneath the Dock even while
the calculator logged `y=24`:

```text
1790872550.706 item-layout-dock-avoidance scene=sceneID:com.macwsguide.host-98A5E4D7-789B-4C5C-85E9-4E5F9CF0C20A dock-height=114.5 container={{0, 0}, {1389, 970}} original={{109, 76.5}, {1171, 817}} result={{109, 24}, {1171, 817}}
```

This runtime/screenshot pair disproved the comment that the returned frame was
authoritative. SpringBoard's immutable
`SBDisplayItemLayoutAttributes.normalizedCenter` remained `{0.5,0.5}`, so a
later consumer continued to place the visible Scene at the old center.

A diagnostic-only readback used the target object's own `centerInBounds:` and
`attributesByModifyingNormalizedCenter:` methods without publishing the probe.
It established the exact coordinate contract on 20D67:

```text
1790873129.927 dock-center-probe scene=sceneID:com.macwsguide.host-98A5E4D7-789B-4C5C-85E9-4E5F9CF0C20A normalized={0.5, 0.5} resolved={694.5, 485} original-frame-center={694.5, 485} desired={694.5, 432.5} delta-normalized={0.5, 0.44587628865979378} delta-result={694.5, 432.49999999999994} absolute-normalized={0.5, 0.44587628865979384} absolute-result={694.5, 432.5}
```

The production correction now runs after Apple's whole-stage auto layout and
publishes a new immutable attributes object with that normalized center,
followed by `appLayoutByModifyingLayoutAttributes:forItem:`. It validates with
SpringBoard's own accessors that the center landed and the model size stayed
identical before returning the adjusted AppLayout. The non-authoritative item
frame hook is no longer modified. Runtime confirmation from the first deployed
pass:

```text
1790873320.028 dock-center-adjusted scene=sceneID:com.macwsguide.host-98A5E4D7-789B-4C5C-85E9-4E5F9CF0C20A dock-height=114.5 container={{0, 0}, {1389, 970}} original={{109, 76.5}, {1171, 817}} target={{109, 24}, {1171, 817}} normalized={0.5, 0.44587628865979378} resolved-center={694.5, 432.49999999999994} size-preserved=YES route=immutable-app-layout
1790873320.291 item-layout-frame scene=sceneID:com.macwsguide.host-98A5E4D7-789B-4C5C-85E9-4E5F9CF0C20A role=1 group-depth=1 skip-auto=YES initial=NO gesture=NO model={1171, 817} frame={{109, 24}, {1171, 817}} initial-grid=NO
```

The larger-than-coexistence path also remains unbounded. A temporary
`1261.5x830` exact-scene resize landed with the full requested size, made the
native Dock yield, and restoring `1261.5x818` released the retained assertion:

```text
1790875039.809 dock-yield-request scene=sceneID:com.macwsguide.host-7661EE4F-9E3A-4D0E-AC3E-9484E10C09C5 frame={{63.75, 70}, {1261.5, 830}} controller=SBFloatingDockController route=native-behavior-assertion level=10
1790875039.923 resize-postcondition scene=sceneID:com.macwsguide.host-7661EE4F-9E3A-4D0E-AC3E-9484E10C09C5 landed=YES role-landed=YES size-landed=YES role=1 center=0 environment=1 expected-windowed=NO expected=1261.5x830.0 actual=1261.5x830.0 size-api=YES samples=1 transaction-attempt=1 stage-members-preserved=YES current-items=sceneID:com.macwsguide.host-7661EE4F-9E3A-4D0E-AC3E-9484E10C09C5 visual-acceptance=UNVERIFIED
1790875040.511 dock-yield-assertion-ready scene=sceneID:com.macwsguide.host-7661EE4F-9E3A-4D0E-AC3E-9484E10C09C5 level=10 presented=NO
1790875059.379 resize-postcondition scene=sceneID:com.macwsguide.host-7661EE4F-9E3A-4D0E-AC3E-9484E10C09C5 landed=YES role-landed=YES size-landed=YES role=1 center=0 environment=1 expected-windowed=NO expected=1261.5x818.0 actual=1261.5x818.0 size-api=YES samples=1 transaction-attempt=1 stage-members-preserved=YES current-items=sceneID:com.macwsguide.host-7661EE4F-9E3A-4D0E-AC3E-9484E10C09C5 visual-acceptance=UNVERIFIED
1790875059.961 dock-yield-released scene=sceneID:com.macwsguide.host-7661EE4F-9E3A-4D0E-AC3E-9484E10C09C5 reason=window-fits-dock-safe-region
```

The repeated internal auto-layout passes can ask for the same immutable model
many times during a transition. Diagnostic witnesses are therefore
deduplicated by exact Scene/original/target geometry; production behavior does
not depend on logging. A final full-iPad visual acceptance remains separate
from these runtime/model witnesses.

## Regression contracts

`misc/test_terminal_tab_dock_contract.py` enforces that:

- same-owner/same-group tab handoff preserves the predecessor frame;
- cross-window paths retain real stream suspension;
- Dock avoidance never mutates `frame.size` or the Scene size policy;
- Dock avoidance publishes only a validated immutable normalized-center
  change after Apple's stock whole-stage layout, and never mutates the
  non-authoritative per-item frame result;
- the native assertion has balanced retention/invalidation;
- full-screen workspace entry and current-stage departure release it.
