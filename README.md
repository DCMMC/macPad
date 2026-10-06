# macPad

A touch-first macOS workspace for jailbroken iPad.

macPad presents a Ventura macOS userspace as native iPadOS windows. macOS arm64
applications run in a chroot; iPadOS keeps control of the kernel, AGX GPU,
display, audio, input, power state, and Stage Manager lifecycle.

[![Historical macPad demo](https://img.youtube.com/vi/SGaiSSRIy8g/0.jpg)](https://www.youtube.com/watch?v=SGaiSSRIy8g)

The video is a historical milestone, not a compatibility or performance
guarantee for the current build.

> [!WARNING]
> macPad is a controlled research beta. It requires a jailbroken test device,
> private/version-specific interfaces, a full macOS filesystem, and recoverable
> backups. Read [AGENTS.md](AGENTS.md) before changing or porting it.

## What works

- iPadOS window mode: macOS windows become independent
  <code>UIWindowScene</code>s with Stage Manager participation.
- Full-workspace mode: Finder, Dock, menu bar, Mission Control, and macOS
  desktop workflows.
- Native IOSurface/Metal presentation with an always-available composited
  fallback and strict direct-drawable acceleration.
- Adaptive 80–120 Hz presentation on validated ProMotion hardware.
- Touch scrolling, selection, move/resize, right-click, zoom/rotate, Mission
  Control gestures, pointer input, and native window constraints.
- Magic Keyboard and software shortcut toolbar routing, including arrows and
  Control/Command chords.
- A Game Camera input mode with iPadOS pointer lock, unbounded Magic Keyboard
  and direct-touch camera motion, automatic activation from an application's
  relative-mouse request. The current absolute-click correction is a guarded
  exact-window candidate and still needs fresh in-game acceptance; it is not
  advertised as fixed.
- iOS Chinese IME composition committed to the exact focused AppKit window.
- Retina Standard and Larger UI modes; unbounded AppKit windows can grow beyond
  the virtual screen when the app itself has no size limit.
- Clipboard, file import/export, cross-app drag and drop, open/save panels,
  audio, location, lock/sleep coordination, and bounded thermal telemetry.
- Scoped compatibility work for VS Code/Electron, Steam, Office, and selected
  macOS system applications.

The renderer does not require VNC or RFB. VNC remains available as a diagnostic
and recovery observer.

## Validated configurations

| Device and system | Jailbreak | macOS userspace | Status |
| --- | --- | --- | --- |
| iPad13,6 (M1), iPadOS 16.3.1 / 20D67 | Dopamine rootless | Ventura 13.4 / 22F66 | Primary and broadest validation target |
| iPad14,5 (M2), iPadOS 16.0 / 20A8372 | Dopamine rootless | Ventura 13.4 / 22F66 | Display, input, audio, VS Code, Steam, and exact arm64 Unity game path validated with narrower coverage |
| iPad14,3 (M2), iPadOS 16.5.1 / 20F75 | Dopamine rootless | Ventura 13.4 / 22F66 | Porting candidate: compiler/AGX/workspace startup reached runtime witnesses, but final unlocked Host pixels and interaction are still pending |
| iPad13,7, iPadOS 16.6 | NathanLR | Ventura experiment | Unsupported by the current CoreTrust/signing chain |
| Other devices/builds | unknown | unknown | Must be treated as a new port |

Do not interpret this as “all M-series or A-series devices work.” Private
framework UUIDs, instructions, GPU ABIs, and jailbreak trust behavior vary by
build. The installer intentionally refuses environments without the
Dopamine-compatible <code>/var/jb/usr/bin/jbctl</code> backend.

Performance is workload-specific. On the recorded M2 window-mode runs, corrected
VS Code TestUFO produced about 117.7–117.9 visible FPS, and a foreground 4K60
YouTube workload produced about 59.2 visible FPS while the panel scheduler
remained near 119.9 Hz. The arm64 Unity 2022.3.62f2 7 Days to Die startup/title
path reached about 116 FPS. That is not an in-world M2 MacBook-equivalent result.
See [dated evidence](docs/evidence/) for exact scope and caveats.

## Rendering policy

macPad uses two layers:

1. Every supported app has a final-composite or exact-window IOSurface/Metal
   fallback.
2. A window or region uses direct-drawable acceleration only when producer
   identity, ownership, geometry, frame sequence, and GPU completion are valid.

Resize, Scene disconnect, or owner change invalidates the direct surface before
fallback. Streams are bounded latest-state channels; a slow consumer drops
obsolete frames instead of growing memory or blocking WindowServer. These rules
are what let smooth 120 Hz presentation coexist with sane heat and power.

## Install and start

macPad does not distribute macOS, Apple private frameworks, commercial apps, or
game data. Obtain the Ventura 13.4 / 22F66 filesystem legally and prepare it at
<code>/var/mnt/rootfs</code>.

For the full prerequisites, large-rootfs resumable transfer, build, trustcache,
and recovery instructions, follow the
[MacWSBootingGuide README](https://github.com/DCMMC/MacWSBootingGuide#readme).
The source trees are intentionally kept aligned; the guide contains the
developer-oriented explanation while this repository is the product-facing
home.

On a prepared Dopamine device with Theos installed:

~~~bash
ssh -p <SSH_PORT> mobile@<DEVICE> \
  'THEOS=/var/jb/var/mobile/theos \
   bash /var/jb/var/mobile/macPad/misc/build_on_ios.sh'
~~~

Or cross-build from macOS:

~~~bash
gmake FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless package install \
  THEOS_DEVICE_IP=<DEVICE> THEOS_DEVICE_PORT=<SSH_PORT> \
  GO_EASY_ON_ME=1
~~~

Run post-install and start the production profile from the iOS shell:

~~~bash
sudo bash /var/jb/usr/macOS/bin/postinst.sh
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh status
~~~

Stop cleanly:

~~~bash
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh stop
~~~

If the stack enters a crash loop or an old profiler/debugger remains active:

~~~bash
sudo bash /var/jb/var/mobile/macPad/misc/cleanup_all.sh
~~~

Do not repeatedly restart WindowServer while it is looping.

## Develop and deploy changes

Use the content-verified device pipeline rather than overwriting a live signed
binary:

~~~bash
export MACWS_DEVICE=mobile@<DEVICE>
export MACWS_DEVICE_PORT=<SSH_PORT>
export MACWS_REMOTE_PROJECT=/var/jb/var/mobile/macPad

bash misc/device_pipeline.sh --sync-only
bash misc/device_pipeline.sh --component host --restart-workspace
bash misc/device_pipeline.sh --component full --restart-workspace
~~~

The pipeline supports <code>runtime</code>, <code>display</code>,
<code>input</code>, <code>workspace</code>, <code>host</code>,
<code>hostd</code>, <code>compiler</code>, <code>libmachook</code>,
<code>metal</code>, and <code>full</code>. It verifies source and installed
artifacts and avoids stale vnode code-signature cache problems.
If this variable is omitted, the shared pipeline's canonical remote default is
<code>/var/jb/var/mobile/MacWSBootingGuide</code>.

Run tests before device acceptance:

~~~bash
python3 -m unittest discover -s misc -p 'test_*.py'
python3 misc/audit_runtime_switches.py
clang -std=c11 -Wall -Wextra -Iinclude misc/macws_protocol_test.c \
  -o /tmp/macws_protocol_test
/tmp/macws_protocol_test
git diff --check
~~~

## Use Codex or another coding agent to port macPad

Start by making the agent read [AGENTS.md](AGENTS.md) completely. That file is
the shared engineering memory for Codex, Claude Code, other agents, and human
maintainers. It records the architecture, exact compatibility matrix, failed
approaches, binary-evidence discipline, test/deploy workflow, and subsystem
invariants.

Suggested prompt:

> Read AGENTS.md completely. Treat my device/build as unsupported until proven.
> Inventory hardware, iPadOS/macOS builds, jailbreak trust backend, rootfs,
> free space, and exact target UUIDs/hashes without changing the device.
> Reproduce one bounded failure and separate FACT from THEORY. Do not use a NOP,
> forced branch, blanket validation bypass, skipped assert, or zero-filled fake
> object as a fix. Trace the upstream producer, support the diagnosis with
> exact-binary disassembly or a copied runtime witness, add a narrow fail-closed
> adapter and tests, validate the visible/protocol endpoint and thermal state,
> write dated evidence, and synchronize MacWSBootingGuide and macPad.

For reliable agent work:

- Use placeholders for addresses and temporary environment variables for
  credentials. Never commit passwords, private keys, NAS credentials, or
  user-specific hostnames.
- Require exact device/build/UUID gates for private binary adapters. Unknown
  identities fail closed.
- Require real acceptance: pixels, advancing frame sequence, input result,
  audio callback, or completed protocol response. Uptime alone is insufficient.
- Preserve the composited fallback; direct-drawable is an optimization, not an
  application requirement.
- Profile before changing pacing. Do not reduce FPS merely to hide heat.
- Close TestUFO, Aquarium, video, and other benchmark windows after every run.
- Add a focused test and a dated note under
  [docs/evidence](docs/evidence/) for every device-only finding.
- Commit and push both repositories separately after shared files are synced.

## Known boundaries

- Stock Steam 7 Days to Die is x86_64 beyond the launcher. iPadOS 16 lacks the
  translated-task/Rosetta kernel contract, so <code>oahd</code> AOT output does
  not make that executable runnable. The validated experiment uses an exact
  arm64 Unity player and legally supplied game data.
- VS Code/Electron and Steam have scoped adapters; success there does not prove
  arbitrary Electron, Chromium, or Steam games work.
- The exact Magic Keyboard + iOS IME routing contract is source/RE verified;
  consult the latest dated evidence before claiming a new physical-keyboard
  combination passed.
- A successful build, install, or long-lived process is not a rendering or
  stability result.
- Apple binaries and proprietary app/game assets must never enter Git.

## Documentation

- [Engineering and agent handbook](AGENTS.md)
- [Architecture](https://github.com/DCMMC/MacWSBootingGuide/blob/main/docs/code-architecture-20260812.md)
- [Display/host design](https://github.com/DCMMC/MacWSBootingGuide/blob/main/docs/displaystream-host-architecture.md)
- [Production-readiness review](https://github.com/DCMMC/MacWSBootingGuide/blob/main/docs/production-readiness-20260912.md)
- [Runtime switches](https://github.com/DCMMC/MacWSBootingGuide/blob/main/docs/runtime-switches.md)
- [Performance profiler](docs/ui-performance-profiler-20260811.md)
- [Evidence index](docs/evidence/)

## Credits

- Codex and other contributors who preserved reproducible tests and evidence
- [khanhduytran0/MacWSBootingGuide](https://github.com/khanhduytran0/MacWSBootingGuide)
- [zhuowei/iOS-run-macOS-executables-tools](https://github.com/zhuowei/iOS-run-macOS-executables-tools)
- [Asahi Linux](https://asahilinux.org/)
