# Exact software-toolbar key routing — 2026-10-01

## Scope

Device: `192.168.1.2`, Dopamine iPad, iOS 16.3.

This change repairs the MacWS virtual-keyboard toolbar's arrows and modifier
chords, makes its own rightmost `键盘↓` button dismiss the UIKit keyboard, and
keeps scrollable toolbar keys outside iPadOS's bottom-right input-method
controls in narrow Stage Manager windows.

## Root cause evidence

Source-confirmed in `macwsinputd/main.c`: the previous
`IsNativeKeyboardProxyRecord` predicate routed every software function keysym
and every Control/Option/Command chord through the global native-keyboard
proxy. That discarded the record's represented AppKit PID/window even though
MacWSHost had emitted it. Plain software text retained AppInput, explaining
why typing worked while arrows and shortcuts did not.

Source-confirmed in `MacWSHost/main.m`: the toolbar's rightmost button was
created with tag zero and shared `softKeyTapped:` with actual key buttons.
That path emitted keysym zero instead of ending the `UITextField` editing
session. It now has a dedicated `dismissSoftwareKeyboardTapped:` action.

## Implemented invariants

- Only real hardware-keyboard records use the native session proxy.
- Every software-toolbar record stays on AppInput with its exact PID/window.
- AppInput makes the represented NSWindow key before delivering all software
  keys, not only committed Unicode, while preserving its first responder.
- The dismiss button is fixed outside the horizontal `UIScrollView`; the
  scroll viewport ends before it. A separate 144-point trailing lane remains
  clear for iPadOS's compact input-method controls.
- Dismiss first flushes marked text, calls `resignFirstResponder`, and uses
  `endEditing:YES` on the view and window if UIKit has not released focus.

## Runtime witnesses

After a full on-device package build/install, `macwsinputd` and MacWSHost were
restarted and a fresh Terminal loaded the new `libmachook` as PID `98624`,
CGWindowID `778`. `misc/macws_virtual_keyboard_runtime_probe.py` sent only the
production 84-byte `MacWSInputRecord` datagrams with source
`MacWSInputSourceSoftwareKeyboard`.

The target Terminal itself created these outputs:

```text
horizontal exists=True bytes=b'abc\n'
vertical exists=True bytes=b'up\nup\ndown\n'
control exists=True bytes=b'ctrl'
```

The horizontal witness uses Control-A, repeated Right, Left, insertion in the
middle of the readline buffer, then Control-E. The vertical witness uses Up
and Down history navigation. The control witness starts `sleep 20`, sends
Control-C, and observes the follow-up command completing immediately with no
remaining `sleep` process.

Command-N created a second real Terminal AppKit window. The production
MacWSHost catalog recorded:

```text
1790855252.130 window-auto-scene candidate identity=98624:g:785 pid=98624 window=785 flags=0x20f reason=new-onscreen-top-level
1790855252.844 window-auto-scene identity=98624:g:785 title=Terminal — bash -i — 80×24 stable-ms=680 flags=0x20f logical=890.0x613.0 minimum=230.0x176.0 fixed=NOxNO
```

These are visible target-side effects rather than process-uptime claims. The
dedicated dismiss action and narrow-window constraints were compile-verified;
the final tap/occlusion check remains a direct UIKit interaction on the iPad.

## Verification

```text
text-input composition and exact Unicode routing PASS
Ran 4 focused tests ... OK
MacWSHost, AppInputBridge, and macwsinputd compile/link/sign ... successful
Full rootless package build/install ... successful
```
