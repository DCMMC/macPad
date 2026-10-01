+# Magic Keyboard routing while iOS IME is active — 2026-10-01

## Scope

Device: `192.168.1.2`, Dopamine iPad13,6, iOS 16.3.

This change is specifically for the physical Magic Keyboard while MacWSHost's
hidden `UITextField` owns first responder so the iOS software keyboard/Chinese
IME can compose text. It is separate from the bottom software-keyboard
toolbar.

## Root-cause evidence

The pre-change `-[MacWSViewController forwardHardwarePressEvent:]` returned
before inspecting any `UIPress` whenever `_keyboardProxy.isFirstResponder`
was true. The pre-change
`-[MacWSViewController observeHardwareModifiersForEvent:]` also called
`releaseHardwareKeyboardState` for that same state. Together those two
branches prevented arrows from reaching `emitKeyPresses:` and erased
Control/Command ownership before the chord key was handled. This is a direct
source diff against the immediately preceding commit, not an inferred UIKit
failure.

RE-confirmed in the installed arm64 MacWSHost UUID
`6913395D-A302-3830-BA12-7C84B939970B`, SHA-256
`fac30acd8a66d46033e76c759d046fb3ec928d9420a1dbf3e9e3293161252185`:

- `forwardHardwarePressEvent:` is at `0x10001927c`. The installed code
  checks only `_appSearchField` at `+68..+104`, reads
  `_keyboardProxy.isFirstResponder` into routing state at `+112..+132`,
  and contains the inlined HID policy at `+560..+616`.
- `observeHardwareModifiersForEvent:` is at `0x100019624`. Its only text
  responder early branch is the app-search field at `+144..+196`; the
  ordinary path calls the Metal view's modifier observer at `+200..+212`.
- The inlined policy rejects pure modifier usages `224..231`, accepts the
  Home-through-arrow cluster `74..82`, and selects Control/Command chords
  while reserving Command-Tab and Command-Space for iPadOS.

These offsets were copied from an LLDB disassembly of the exact binary copied
back from `/var/jb/Applications/MacWSHost.app/MacWSHost` after package
installation.

## Implemented invariant

At the `UIWindow sendEvent:` boundary, before UIKit chooses its responder:

- unmodified printable keys and Shift/Option composition remain with UIKit, so
  the active Chinese IME continues receiving text;
- arrows/navigation keys go to the represented AppKit window;
- Control/Command chord keys go to the represented AppKit window;
- pure modifier edges remain visible to UIKit and are mirrored through the
  existing source-4 modifier-snapshot route;
- Command-Tab and Command-Space remain iPadOS system shortcuts.

No protocol check, assert, or setup call is bypassed. The change repairs
ownership upstream and reuses the existing hardware-key mapping and AppInput
transport.

## Verification

The framework-free HID policy test compiles the same inline function with
Clang, UBSan, `-Wall -Wextra -Werror`, and exercises all printable HID usages,
the modifier usages, navigation cluster, and reserved iPadOS shortcuts. Source
contract tests also prove that the keyboard proxy is no longer an early return
in either window-boundary method.

```text
MacWSBootingGuide: Ran 611 tests in 53.882s — OK (skipped=13)
macPad:            Ran 615 tests in 54.028s — OK (skipped=13)
MacWSHost arm64 compile/link/sign — successful
Full rootless package build/install/postinst — successful
```

The package was installed and MacWSHost restarted as PID `20059`. The iOS
software keyboard was reopened on AppKit PID `98624`, window `786`; runtime
log records `software-keyboard-focus ... activated=YES`. A final physical
Magic Keyboard key-down/up witness is intentionally not claimed here until a
keyboard event is produced after this restart.

