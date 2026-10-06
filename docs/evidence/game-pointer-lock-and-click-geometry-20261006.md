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

## Initial offset evidence

The same Stray run recorded these Host lines:

```text
1791237137.849 fullscreen-canvas-capability pid=43493 window=441 source=controller-validated-catalog canvas=2388x1668
1791237144.168 direct-drawable-heartbeat pid=43493 layer=441 drawable=1400x900 canvas=1194x834 identity=retained-live-fullscreen-canvas
1791237144.178 direct-drawable-heartbeat pid=43493 layer=441 drawable=1280x894 canvas=1194x834 identity=retained-live-fullscreen-canvas
1791237300.685 game-pointer-motion sample=1920 pid=43493 window=441 source=3 delta=(16,-7) frame=1280x894
```

Runtime-confirmed: the Host's fullscreen canvas and completed direct drawable
used different pixel extents. This trace alone did **not** prove the exact
AppKit window origin or logical rectangle; the earlier text incorrectly
promoted the canvas extent to the window geometry.

## Rejected first calibration

The first calibration retained the exact PID/window catalog backing dimensions
and changed an absolute record from the direct presentation extent to that
backing extent. The user then runtime-confirmed that the click offset was
completely unchanged.

Source-confirmed in `MacWSPostDockSystemInput`: the zero-window fullscreen
route computes `record.x / record.frameWidth` and
`record.y / record.frameHeight`. The first change multiplied the coordinate
and its declared frame by the same factor, so those quotients—and therefore
the CGEvent position—were identical. That patch separated names and sizes but
did not alter the delivered click. It is not an accepted fix.

## Follow-up invariant under test

Source-confirmed in the pre-follow-up `emitKind:touch:point:extraFlags:`:
while Game Camera pointer lock was ready, every indirect-pointer button event
discarded `[touch locationInView:]` and replaced it with the input-frame
center. Source-confirmed in `routeFullscreenInputRecord:`: that synthetic
center was then sent through Dock's zero-window global CGEvent route even
though the completed drawable and exact AppInput PID/window were already
authenticated. Thus a visible game button away from the center could not
receive the point the user actually pressed. This is independent of the
rejected proportional frame relabel above.

The follow-up candidate preserves UIKit's button point, inverses the exact
Metal visible-source transform, and expresses the result in the retained
AppKit window's backing-pixel domain. Only a completed direct drawable whose
PID/window still matches that retained catalog identity and whose AppInput
endpoint is live takes this route. It is delivered to that exact application
endpoint; ordinary fullscreen desktop, Dock, Mission Control and unsupported
geometry continue through the existing global WindowServer route. The iPad's
`UIScreen.bounds` is deliberately absent because UIKit Scene points are not a
macOS desktop or AppKit-window coordinate authority.

This section describes the implementation candidate, not runtime acceptance.
The actual Stray click must still be captured from the newly added
`pointer-click-map`, `fullscreen-input-geometry`, and
`fullscreen-direct-pointer-map ... route=exact-app-input` lines before this
can be called fixed.

The retained backing-domain separation remains necessary for Host hit testing:

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

These gates describe the rejected first deployment. The follow-up candidate is
not recorded as accepted until its own deploy, runtime trace, visible click
witness, cleanup, and complete regression run have finished.
