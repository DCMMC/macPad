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

## Follow-up: whole-stage return was still transient

The user reproduced the overlap again with the deployed immutable whole-stage
clone. Diagnostics were enabled in the live SpringBoard process by changing
only the plugin's cached diagnostic byte, without restarting SpringBoard or
changing the Scene. The current exact Scene then produced:

```text
1790877358.160 dense-grid-result grid=0x283955c80 proposed=1179.0x814.0 constrained=1179.0x814.0 result=1179.0x814.0 candidates=128x83 stock=8x4 policy=sceneID:com.macwsguide.host-0639659E-23D5-4BB2-9F4F-CC1FE38DC61D
1790877358.160 dock-center-adjusted scene=sceneID:com.macwsguide.host-0639659E-23D5-4BB2-9F4F-CC1FE38DC61D dock-height=114.5 container={{0, 0}, {1389, 970}} original={{105, 78}, {1179, 814}} target={{105, 24}, {1179, 814}} normalized={0.5, 0.44432989690721647} resolved-center={694.5, 431} size-preserved=YES route=immutable-app-layout
```

The current visible model had therefore retained center `y=485` (`frame y=78`)
despite the later calculator returning a validated clone centered at `y=431`
(`frame y=24`). The user's simultaneous visual report plus this exact-Scene
runtime witness disproved the assumption that returning the clone from
`_appLayoutByPerformingAutoLayoutIfNeededInAppLayout:...` commits it to the
persistent switcher model.

This is consistent with the actual 20D67 transaction constructor already
RE-confirmed at `0x1c79cfaf4`: native resizing receives both `size` and
`center`, creates immutable display-item attributes, clones the AppLayout and
builds the transition request there. The correction must therefore enter at
that transaction boundary. Native gestures now pass a Dock-safe center into
the original response constructor. Programmatic AppKit-driven resizing writes
the equivalent validated normalized center into the same immutable attributes
object that carries its size before cloning the transition AppLayout. The
whole-stage clone remains a transient layout fallback, not the persistence
mechanism. When an oversized window shrinks enough to release a retained Dock
assertion, that same transaction also carries the translated center instead
of waiting for another non-persistent layout pass.

This change still needs fresh full-iPad visual acceptance after deployment;
the evidence above proves the previous implementation was incomplete, not
that the new transaction-boundary implementation is visually accepted.

## Follow-up: authoritative native resize transaction

The transaction-boundary implementation was then deployed on the same
iPad13,6 / 20D67 target. A real native resize gesture produced successive
unchanged-size transactions whose center moved upward as the window grew. The
last coexistence-sized samples were:

```text
1790879378.703 dock-center-transaction scene=sceneID:com.macwsguide.host-10616729-7356-433C-818B-41098E9D7C42 source={695, 485.5} target={695, 453.5} size={1178, 756} route=native-resize-response
1790879378.717 dock-center-transaction scene=sceneID:com.macwsguide.host-10616729-7356-433C-818B-41098E9D7C42 source={695, 485.5} target={695, 452.5} size={1180, 758} route=native-resize-response
1790879378.733 dock-center-transaction scene=sceneID:com.macwsguide.host-10616729-7356-433C-818B-41098E9D7C42 source={695, 485.5} target={695, 452.5} size={1182, 758} route=native-resize-response
1790879378.876 dock-center-transaction scene=sceneID:com.macwsguide.host-10616729-7356-433C-818B-41098E9D7C42 source={695, 485.5} target={695, 451.5} size={1182, 760} route=native-resize-response
```

This is the first runtime witness from the actual native response constructor,
not the previously disproved late frame/whole-stage paths. The full requested
size is preserved while the center is incorporated into the same immutable
SpringBoard resize transaction. A fresh full-iPad visual capture or user
acceptance is still required before claiming that every Dock presentation
transition is visually accepted.

## Follow-up: asynchronous assertion-release race

The next user reproduction exposed a second, independent lifecycle problem.
During one native resize gesture, transient models crossed above and below the
Dock-coexistence threshold. The same Scene created a yield assertion, reached
its hidden-Dock completion, and then created another assertion shortly after:

```text
1790879379.516 dock-yield-request scene=sceneID:com.macwsguide.host-10616729-7356-433C-818B-41098E9D7C42 frame={{120.5, 24}, {1149, 835.5}} controller=SBFloatingDockController route=native-behavior-assertion level=10
1790879380.212 dock-yield-assertion-ready scene=sceneID:com.macwsguide.host-10616729-7356-433C-818B-41098E9D7C42 level=10 presented=NO
1790879381.080 dock-yield-request scene=sceneID:com.macwsguide.host-10616729-7356-433C-818B-41098E9D7C42 frame={{105.5, 24}, {1179, 833}} controller=SBFloatingDockController route=native-behavior-assertion level=10
1790879381.771 dock-yield-assertion-ready scene=sceneID:com.macwsguide.host-10616729-7356-433C-818B-41098E9D7C42 level=10 presented=NO
1790879384.042 dock-center-adjusted scene=sceneID:com.macwsguide.host-10616729-7356-433C-818B-41098E9D7C42 dock-height=114.5 container={{0, 0}, {1389, 970}} original={{93.25, 76}, {1202.5, 818}} target={{93.25, 24}, {1202.5, 818}} normalized={0.5, 0.44639175257731961} resolved-center={694.5, 433} size-preserved=YES route=immutable-app-layout
```

There was no `dock-yield-released` completion for the final assertion before
the next SpringBoard generation. The old implementation removed its only
retained dictionary entry before calling asynchronous
`invalidateWithCompletion:`. The candidate correction keeps that exact
assertion strongly retained until completion, suppresses duplicate release
requests, and records a newer oversized geometry decision so completion can
reassert native yield when needed. It still never changes the authoritative
window size. This correction is deployed, but a fresh same-Scene runtime
release line and user visual acceptance remain required.

## Follow-up: retained assertion was not live authority

The next exact-height reproduction showed that retention alone was not a
valid assertion-state witness. SpringBoard made the Dock visible again while
the Scene still retained an assertion whose `invalidateWithCompletion:`
callback never arrived:

```text
1790913015.425 dock-yield-state scene=sceneID:com.macwsguide.host-4121D78E-59CD-48C4-9CF2-6EC79CA1A173 active-level=9 active-progress=1.000
1790913015.426 dock-yield-request scene=sceneID:com.macwsguide.host-4121D78E-59CD-48C4-9CF2-6EC79CA1A173 frame={{125.5, 24}, {1139, 831.5}} controller=SBFloatingDockController route=native-behavior-assertion level=10
1790913016.140 dock-yield-assertion-ready scene=sceneID:com.macwsguide.host-4121D78E-59CD-48C4-9CF2-6EC79CA1A173 level=10 presented=NO
```

There was still no release completion more than sixty seconds later, while a
full iPadOS capture at `1790913077` visibly showed the Dock overlapping the
retained large window. `MacWSRequestFloatingDockYield` had returned success
only because its dictionary still contained an object. The corrected
lifecycle checks the controller's live `isFloatingDockPresented` state,
recycles a retained assertion that has lost authority, and binds release
completion to the exact assertion generation. A 2.5-second main-queue timeout
finishes a generation whose callback is omitted; late callbacks cannot clear
its replacement. The first deployed timeout witness was:

```text
1790913716.833 dock-yield-released scene=sceneID:com.macwsguide.host-77DEF787-3FFE-4477-A192-D9BFCC9389C5 reason=window-fits-dock-safe-region reassert=NO completion=timeout
```

This repairs assertion ownership; it does not impose a maximum height or
change the requested Scene size.

## Follow-up: post-gesture transition overwrote the safe center

The user reproduced overlap again at the final `1229.2x825.5` size. The exact
Scene emitted a real gesture response and then, 34 ms later, a same-size
system-transition response after the gesture scope had ended:

```text
1790913716.052 resize-response host scene=sceneID:com.macwsguide.host-77DEF787-3FFE-4477-A192-D9BFCC9389C5 proposed=1229.2x825.5 constrained=1229.2x825.5 policy=scene-gesture
1790913716.053 dock-center-adjusted scene=sceneID:com.macwsguide.host-77DEF787-3FFE-4477-A192-D9BFCC9389C5 dock-height=114.5 container={{0, 0}, {1389, 970}} original={{79.877807618118823, 72.25}, {1229.2443847637624, 825.5}} target={{79.877807618118823, 24}, {1229.2443847637624, 825.5}} normalized={0.5, 0.4502577319587629} resolved-center={694.5, 436.75} size-preserved=YES route=immutable-app-layout
1790913716.086 resize-response ignored scene=sceneID:com.macwsguide.host-77DEF787-3FFE-4477-A192-D9BFCC9389C5 proposed=1229.2x825.5 constrained=1229.2x825.5 source=system-transition
```

An LLDB disassembly of the exact original 20D67 SpringBoard IMP at live
`0x216877af4` (unslid `0x1c79cfaf4`) established why the latter call matters.
At `+176..+200` it passes the method's `center` argument to
`normalizedPointForPoint:inBounds:`; at `+204..+212` that result goes to
`attributesByModifyingNormalizedCenter:`. Only afterward, at `+304..+340`,
does it infer and publish the attributed size. Thus the same-size follow-up is
also an authoritative center publisher, not a harmless observer.

The correction admits Dock-center policy to a non-gesture call only when both
dimensions match the last real gesture sample within one point. Unrelated
restore/reflow proposals remain excluded, preserving the prior fixed-window
protection. The expected new witness is
`route=matching-system-followup`; full-iPad visual acceptance is still
required before marking this reproduction closed.

## Final correction: global switcher frame provider (2026-10-02)

The user reproduced one remaining sequence: launch correctly, shrink the
window, then enlarge it to a size that still fits beside the Dock. The size was
valid, but the final presentation was recentered against the full `1389x970`
container. A diagnostic A/B changed the local
`frameForLayoutRole:inAppLayout:withBounds:` origin from `0.5` to `-51`, yet
the reusable container still landed at full-screen center `y=485`:

```text
1790921980.891 layout-role-frame-adjusted ... bounds={{0,0},{1389,970}} original={{0,0.5},{1167.5,819}} result={{0,-51},{1167.5,819}} size-preserved=YES
1790921980.977 ... container-set-center ... frame={{111,76},{1167.5,819}} center={694.75,485}
```

That rejected the local-role frame as the final positioning authority.
RE-confirmed on SpringBoard UUID
`13B37E5E-5290-3E2E-91B9-4378BD2E8312`: the block beginning at
`0x1c77537e4` obtains the AppLayout index, sends `anchorPointForIndex:` at
`0x1c7753884`, then sends `frameForIndex:` at `0x1c7753898`. Its global frame
origin is combined with the anchor-derived offset at `0x1c7753e74` and
`0x1c7753eb8`; the nested presentation block finally calls `setCenter:` at
`0x1c7756534`. Runtime Objective-C ivar metadata identified the exact receiver:

```text
1790922796.520 frame-for-index-ivar scene=sceneID:com.macwsguide.host-... owner=SBGridSwitcherViewController ... ivar=_rootModifier offset=1832 candidate=SBiPadOSPlatformSwitcherModifier ... responds=YES ... route=fluid-switcher-ivar
```

The production fix therefore intercepts only
`SBiPadOSPlatformSwitcherModifier -frameForIndex:`. It resolves the AppLayout
at that exact index, requires an exact non-workspace
`com.macwsguide.host` Scene, and translates the returned global frame through
the existing live Dock geometry helper. It does not change either dimension,
introduce a height ceiling, snap to stock size presets, or hook a `UIView`
setter. The accepted run changed only the origin:

```text
1790922836.154 index-frame-provider scene=sceneID:com.macwsguide.host-... provider=SBiPadOSPlatformSwitcherModifier index=1 bounds={{0, 0}, {1389, 970}} dock-height=114.5 original={{64.5, 76.5}, {1260, 817.5}} result={{64.5, 24}, {1260, 817.5}} size-preserved=YES route=switcher-global-frame
1790922836.155 page-view-frame-producer scene=sceneID:com.macwsguide.host-... fully-presented=YES frame={{0, 0}, {1260, 817.5}} container-frame={{65, 23.5}, {1260, 817.5}} container-center={694.5, 432.75} route=fluid-switcher-delegate
```

A full iPadOS capture showed the unchanged large window ending above the
visible Dock, and the user confirmed the original shrink-then-enlarge
reproduction was fixed. All temporary view-setter, role-provider and ivar
inventory hooks were removed after acceptance. The retained diagnostic for
the exact global provider is opt-in and deduplicated by Scene and geometry.

## Regression contracts

`misc/test_terminal_tab_dock_contract.py` enforces that:

- same-owner/same-group tab handoff preserves the predecessor frame;
- cross-window paths retain real stream suspension;
- Dock avoidance never mutates `frame.size` or the Scene size policy;
- Dock avoidance publishes a safe center in both native-gesture and
  programmatic authoritative resize transactions, keeps the whole-stage clone
  only as a transient fallback, and never mutates the non-authoritative
  per-item frame result;
- the final `SBiPadOSPlatformSwitcherModifier -frameForIndex:` path translates
  only an exact Host Scene, preserves both dimensions, and ships without
  presentation-layer setter hooks;
- the immediate system-transition follow-up inherits the safe center only
  when its size matches the last real gesture sample;
- the native assertion has balanced retention/invalidation;
- asynchronous invalidation retains the exact assertion through completion
  and reasserts only when a newer geometry pass still requires Dock yield;
- full-screen workspace entry and current-stage departure release it.
