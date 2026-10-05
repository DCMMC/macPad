# Game pointer lock and absolute click geometry — 2026-10-06

## Scope

This note records the relative-pointer implementation and the follow-up
absolute-click calibration on the validated M1 / iPadOS 16.3.1 target. The
implementation is route- and geometry-based; it contains no game bundle-ID or
device-model exception.

## Relative pointer acceptance

The user runtime-confirmed that the completed path was functional before the
click calibration: horizontal camera motion, corrected vertical direction,
unbounded Magic Keyboard camera motion, unbounded direct-touch camera motion,
and automatic entry driven by the application's relative-pointer request all
worked. The only reported remaining defect was an offset between a visible
game button and its absolute click target.

The relative route is fail-closed until UIKit reports the Scene's pointer lock
as active. `GCMouse` deltas then travel as
`MacWSInputKindRelativePointer` to the exact application/window endpoint;
inputd does not fall back to the global cursor for this record kind. Direct
touch in Game Camera mode uses the same relative record rather than a bounded
absolute cursor.

## Offset evidence and root cause

The same Stray run recorded these Host lines:

```text
1791237137.849 fullscreen-canvas-capability pid=43493 window=441 source=controller-validated-catalog canvas=2388x1668
1791237144.168 direct-drawable-heartbeat pid=43493 layer=441 drawable=1400x900 canvas=1194x834 identity=retained-live-fullscreen-canvas
1791237144.178 direct-drawable-heartbeat pid=43493 layer=441 drawable=1280x894 canvas=1194x834 identity=retained-live-fullscreen-canvas
1791237300.685 game-pointer-motion sample=1920 pid=43493 window=441 source=3 delta=(16,-7) frame=1280x894
```

Runtime-confirmed: the exact AppKit window/catalog geometry was `2388x1668`
backing pixels while the direct drawable changed to `1280x894`. Source-confirmed
in the pre-fix `MacWSMetalView`: absolute records used
`currentFrameWidth/currentFrameHeight`, which describe the presentation
surface. AppInput normalizes an exact-window record by its declared frame
dimensions. Consequently, a direct drawable's internal render resolution was
incorrectly treated as the AppKit input geometry.

## Fix

`MacWSMetalView` now retains the exact PID/window catalog geometry when the
fullscreen canvas identity is validated. Absolute input records use that
authoritative AppKit backing-pixel domain. Host-only hit testing separately
projects the normalized point into the currently presented surface through
`MacWSInputPointInPresentationSpace`; the record delivered to inputd/AppInput
is not rewritten to the drawable's resolution.

This separation is necessary for both sides of the invariant:

- AppKit/CGEvent delivery sees the exact window geometry, so visible buttons
  and click targets share one normalized coordinate.
- Host layer resolution still sees presentation pixels, so a `2388x1668`
  input point is not accidentally tested as a raw location in a `1280x894`
  drawable.

The retained geometry is scoped to the exact validated PID/window identity and
is cleared on target/window transitions. A temporary catalog gap may retain
only that same identity; it cannot leak into another application.

## Build and regression gates

The Host component was built, signed and installed through
`misc/device_pipeline.sh --component host`. The pipeline reported
`artifact invariant: ready`; the installed Host SHA-256 was:

```text
7a7c0beb52a66933313808f7614bd5680a395674d07be7d00364e4bebb62229e
```

The post-install idle check reported
`thermal-state=nominal effective-temp-centic=3389`; no game, TestUFO or
Aquarium process was left running.

Local gates:

```text
python3 -m unittest discover -s misc -p 'test_*.py'
Ran 645 tests in 63.158s — OK (skipped=13)

python3 misc/audit_runtime_switches.py
runtime-switch audit OK: 286 source/plist env names, 85 source flag files, 443 total recorded entries

misc/macws_protocol_test.c
macws protocol validators: PASS

bash -n misc/device_pipeline.sh misc/cleanup_all.sh layout/usr/macOS/bin/macos_gui.sh
git diff --check
```

The focused static contract also checks that the absolute click path retains
catalog geometry and explicitly converts only Host's resolver point into the
presentation domain.
