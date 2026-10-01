# iOS IME to exact AppKit text focus — 2026-10-01

## Scope

Device: `192.168.1.2`, Dopamine iPad, iOS 16.3.

The production MacWSHost text proxy now lets UIKit own marked-text
composition, forwards only committed Unicode, and retains the selected
macOS window plus its existing AppKit first responder. The same change also
keeps the MacWS function row clear of iPadOS's bottom-right input-method
control without adding a strip below the rendered macOS content.

## Runtime witnesses

The installed iOS keyboard inventory included Simplified Chinese Pinyin:

```text
en_US@sw=QWERTY;hw=US
zh_Hans-Pinyin@sw=Pinyin-Simplified;hw=ABC
emoji@sw=Emoji
```

After deploying MacWSHost, macwsinputd, and libmachook, a fresh production
Terminal was resolved as PID `80418`, exact CGWindowID `747`. The bounded
runtime probe sent a shell command through
`/private/tmp/macws_host_input.sock`; the Chinese character itself travelled
as software-keyboard keysym `0x01004f60` rather than being written by the
probe. The target shell produced:

```text
sent exact-window Unicode command to pid=80418 window=747
PROBE_BYTES e4bda0
PROBE_UTF8 你
```

The user then manually confirmed on the iPad that Chinese input works. This
is the visible-output witness; process uptime alone was not used as success.

## Implemented invariants

- `UITextField` marked text remains local to UIKit until composition commits.
  The sentinel buffer still makes Backspace observable.
- Encoded Unicode (`0x01xxxxxx`) is disjoint from X11 function keysyms
  (`0xff00..0xffff`) and remains on the exact AppInput route.
- A Unicode commit resolves the requested NSWindow, makes it key if needed,
  preserves its existing `firstResponder`, and creates an NSEvent carrying
  that exact window number.
- Control/Option/Command shortcuts and real function keys retain the native
  keyboard proxy route.
- The function row stays pinned to the root bottom. Its scroll viewport uses
  a 72-point trailing exclusion lane when the system keyboard is compact or
  floating; a docked, full-width software keyboard removes that exclusion.

## Verification

```text
text-input composition and exact Unicode routing PASS
Ran 4 tests ... OK
MacWSHost arm64 compile/link/sign ... successful
Full rootless package build/install ... successful
```

The two repositories carry byte-identical implementations and focused tests.
