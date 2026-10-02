# AGENTS.md

This is the authoritative operating memory for coding agents and human
maintainers working in this repository. `CLAUDE.md` points here so Codex,
Claude Code, and other agents share one set of constraints and facts.

## Project Overview

MacWSBootingGuide is a WIP jailbreak project that enables running macOS's WindowServer (and macOS GUI applications) on jailbroken iOS/iPadOS devices (arm64, Dopamine rootless jailbreak). It works by chrooting into a bind-mounted macOS filesystem and using dyld interpositioning to patch incompatible system calls and framework behaviors at runtime.

## Patch Discipline (load-bearing rule — read first)

This codebase has burned multiple sessions on patches that LOOK fixed because
the immediate crash stopped but actually leave the underlying invariant
broken, then cascade into worse failures. Don't do this.

**A symptom-suppressing patch is NOT a fix.** If your change is one of:

- `bl <thing> → nop` (the thing was supposed to run; NOPing it skips setup
  that downstream code assumes ran)
- `b.{eq,ne,hi,hs} → b` (forcing a path the original wouldn't take; the
  unforced path's preconditions still apply to what runs after)
- Hooking a check function (`validateBufferTextureWithSize:`,
  `someInternalThing` etc.) to always return 1 / YES / non-nil
- Blanket-bypassing `__assert_rtn`, `abort_with_payload`, `objc_release`,
  any class-wide method override returning a constant
- "If nil, calloc a zero buffer and return that as a stub"
- Filling `Device->X` / `this->Y` with a zero blob "so the deref doesn't
  crash"
- An env-gated `if (getenv("MACWS_X")) skip_check();` for an actual
  protocol check, not just a diagnostic toggle

then call it a **diagnostic** or **temporary scaffold**, **not** a fix.
Either keep going to find the root cause, or label it explicitly so the
next reader knows it's a marker that something is still broken.

**The right layer is upstream.** If a buffer field is nil where it
shouldn't be, the question is "what was supposed to fill it" — and then
"why didn't that fill succeed". Walking down into the crashing function
and NOPing past the deref is working at the wrong layer.

**Process uptime ≠ stability.** A process whose `__assert_rtn` is
globally bypassed can stay alive while quietly leaking state every frame.
Witnesses for stability are: visible output (VNC pixels, completed XPC
round-trips), counters advancing, frames landing. Not `etime`.

**Existing band-aids that exemplify what NOT to repeat:**

| Patch (was/is in tree) | Why it was wrong | Real fix |
|---|---|---|
| `Mempool::grow b.hs → b` NOP (commit `4124628`, rolled back by `098690e`) | Skipped freelist init; downstream `newBuffer` read uninit storage and crashed worse | `MACWS_AGX_REGISTER_CLASSES=1` walks `__objc_classlist`+`objc_readClassPair` so `objc_alloc(AGXBuffer)` actually works → lambda fills the chunks legitimately |
| `findOrCreate<X>ProgramVariant` stub-prologue 5-insn `movz/movk*3/ret 0x1000-byte calloc` (whack-a-mole, removed by `247da92`) | Every new variant lookup was its own null deref | NSBundle registration via `bundleWithPath:` + `loadAndReturnError:` so `setupCompiler:`'s `pathForResource:ds.g13g` resolves → `Device->0x318` (AGX::Compiler*) is real → ALL variant lookups succeed naturally |
| Blanket `__assert_rtn → log+return` (still in tree, **lazy**) | Masks `_state_stack.empty() "Unbalanced Composites"` at MetalContext.mm:411 → SkyLight composite state stack leaks every frame | Find why intermediate composite ops early-return (currently ResCreate FAIL inside AGXIOC) and fix THAT |

The catalogue above is the durable replacement for the former private-agent
memory note. Use the `MACWS_AGX_CRASH_DIAG` register and memory dump in
`mac_hooks.m` to turn this class of crash into a reproducible root-cause trace.

## Evidence Discipline (load-bearing rule — read second)

**Hard rule: every claim about why something is broken must be backed by
either (a) decompiled code from the actual binary involved (otool /
capstone / lldb disasm of the specific function), or (b) a runtime log
line / lldb register dump / crash report excerpt that you copied verbatim
from the running system.**

No hypotheses promoted to fact without one of those two artifacts.
Examples of statements that fail this rule:

- "The kernel rejects because of signature check" — without showing the
  disasm of the rejection point.
- "asyncReference must be non-NULL" — without dumping it from a kernel
  externalMethod breakpoint.
- "iOS sends a different args layout" — without disasming both
  iOS and macOS userland's call sites.

When a claim IS RE-backed, label it: `RE-confirmed via <file>+<offset>`
or `runtime-confirmed via <log/crash filename>`. When it's a guess,
label it THEORY and add what evidence would confirm/refute it.

This rule exists because we've burned multiple sessions chasing theories
that felt obvious but were wrong. Two recent examples that the discipline
caught:

1. "macOS binary lacks signing identity for private GPU operations"
   hypothesis — disproven by capstone disasm of
   `IOGPUDeviceUserClient::externalMethod` at `0xfffffe0009eed344`
   showing the kernel does NOT check signing or entitlement strings in
   that path.

2. Then we hypothesized "the rejection is from a per-user-client
   `device->0x108` size limit that gets zero'd for unprivileged opener".
   Also disproven: `misc/agx_iogpu_probe.c` (iOS-native KRW reader) opened
   an AGXAccelerator UC and walked
   `task_get_ipc_port_kobject → UC+0x120 → IOGPUDevice+0x48 → IOGPU`
   to find `IOGPU+0x108 = 0x139ce0000` (5.13 GB cap) AND that IOGPU is a
   real singleton (same kernel address across multiple matching paths,
   so chroot sees same value). The size check trivially passes. UC+0x103
   = 0 → not the saaramar restricted-method-table mechanism either.
   The actual reject site that returns `0xe00002c2 = kIOReturnNoBandwidth`
   is elsewhere in `IOGPUFamily` and is still being RE'd.

The corrected attribution is retained in the historical AGX snapshot below so
it is available to every agent without an external memory store.

## Current Project Memory and Operating Baseline (2026-10-02)

This section is the current summary. Later sections retain detailed and
historical bring-up knowledge. If an older section conflicts with this one,
the current source, focused tests, dated evidence under `docs/evidence/`, and
this section take precedence—in that order.

### Product and release status

MacWS/macPad is a controlled research beta that runs a Ventura 13.4 macOS
userspace and WindowServer on jailbroken Apple-silicon iPads. macOS arm64 code
runs natively; iPadOS remains responsible for the kernel, AGX GPU, display,
audio hardware, UIKit windows, touch, pointer, keyboard, power state, and
memorystatus policy.

This is not a VM and not a remote-desktop product. The production UI maps
macOS windows into iPadOS `UIWindowScene`s and transports IOSurfaces into an
iOS-native Metal host. VNC remains a diagnostic/recovery observer; it is not
the normal presentation path.

Do not describe the project as generally production-ready or compatible with
all M-series/A-series devices. Private frameworks, Mach-O UUIDs, instruction
patterns, GPU ABIs, and jailbreak trust behavior are version-specific.

### Validated platform matrix

| Device / OS | Jailbreak | macOS userspace | Evidence-backed status |
|---|---|---|---|
| iPad13,6 (M1), iPadOS 16.3.1 / 20D67 | Dopamine rootless | Ventura 13.4 / 22F66 | Primary and broadest validation target: native AGX desktop, window/fullscreen Host, 120-Hz paths, input/IME, VS Code, Steam, Office workloads, system apps and interop |
| iPad14,5 (M2), iPadOS 16.0 / 20A8372 | Dopamine rootless | Ventura 13.4 / 22F66 | Exact MTLCompilerService UUID adapter, VS Code web rendering, Steam/arm64 Unity 7DTD, direct presentation and audio paths validated; coverage is narrower than M1 |
| iPad13,7, iPadOS 16.6 | NathanLR | Ventura rootfs experiment | Unsupported: runtime-confirmed CoreTrust signing cannot admit the patched macOS shared-cache closure and AMFI rejects the helper; package install fails closed without `/var/jb/usr/bin/jbctl` |
| Any other device/build | unknown | unknown | Porting target, not supported until its identities, ABI and runtime witnesses are added |

The current package structurally requires a Dopamine-compatible dynamic
trustcache backend. Do not install or replace a user's jailbreak, and do not
weaken the postinstall refusal on NathanLR to make installation appear to
work.

Never commit passwords, SSH private keys, API keys, NAS credentials, public
addresses, or user-specific hostnames. Use placeholders in documentation and
temporary environment variables such as `MACWS_DEVICE`,
`MACWS_DEVICE_PORT`, and `MACWS_SUDO_PASSWORD`. Rotate any credential exposed
during an interactive debug session.

### Current end-to-end architecture

```text
macOS application / WindowServer in Ventura chroot
  ├─ libmachook: exact runtime compatibility, input bridge, Metal hooks
  ├─ AppInputBridge: exact PID/window AppKit delivery and metrics
  ├─ WindowServer final composite or exact-window IOSurface stream
  └─ qualifying producer: authenticated completed direct drawable
                         │ Mach right + versioned descriptor
                         ▼
macwsdisplayd / macwsinputd / macwsinteropd
  ├─ validate sender identity, dimensions, sequence and ownership
  ├─ retain latest state with bounded in-flight surfaces
  └─ route input/clipboard/files to the represented macOS owner
                         │
                         ▼
MacWSHost + MacWSWindowing on iPadOS
  ├─ one macOS logical window per UIWindowScene
  ├─ native Metal presentation into the iPad drawable
  ├─ UIKit touch, pointer, keyboard, IME and Stage Manager integration
  └─ macwshostd lifecycle, app launch, lock/sleep and service recovery
```

Production rendering follows a layered policy:

1. Every supported application has an IOSurface/Metal presentation path. The
   exact-window stream is the ordinary window-mode fallback; WindowServer's
   completed final composite is authoritative for the full Aqua workspace.
2. A window or region may use direct-drawable acceleration only after strict
   producer identity, owner/window, geometry, sequence and completion checks.
3. A resize, scene disconnect, owner transition or stale geometry invalidates
   the direct surface before fallback resumes. Never stretch or retain an old
   drawable through a geometry transition merely to keep FPS high.
4. Streams are latest-state, not unbounded FIFOs. Producer and consumer lease
   counts are bounded; a slow consumer drops obsolete work instead of growing
   memory or blocking WindowServer.

Important component ownership:

- `MacWSHost/`: iOS Scene UI, Metal presentation, gestures, keyboard/IME,
  performance monitor, direct-drawable receiver and compositor.
- `MacWSWindowing/`: SpringBoard/Stage Manager integration and Scene geometry.
- `macwshostd/`: trusted iOS-side lifecycle, app launcher, sleep coordinator,
  Steam helpers and service recovery.
- `libmachook/`: injected macOS-side compatibility and interposition. Keep
  unrelated policies out of the monolithic files when a protocol-owned module
  exists.
- `macwsdisplayd/`: authenticated display receive/catalog boundary.
- `macwsinputd/` + `libmachook/AppInputBridge.m`: versioned input transport and
  exact AppKit delivery.
- `macwsinteropd/`: clipboard/file/drag interoperability.
- `macwsaudiooutd/`: iOS-native hardware output for the shared PCM ring.
- `autosignd/` + postinstall scripts: exact dependency-closure signing and
  Dopamine trustcache admission.
- `MTLCompilerBypassOSCheck/`: exact-UUID compiler-service request adapter.
- `misc/metal2metal.py` and related modules: fail-closed AIR-to-AIR profiles;
  this is not a generic shader or Metal validation bypass.
- `MTLSimDriverHost/`: legacy/diagnostic compatibility. Native AGX is the
  production target.

### Evidence-backed user-visible state

Display and windows:

- Window mode and full Aqua workspace run through IOSurface/Metal rather than
  RFB encoding.
- A 120-Hz panel is configured with an 80…120 Hz adaptive range. Corrected
  VS Code TestUFO window-mode runs delivered about 117.7–117.9 visible FPS;
  foreground YouTube 4K60 delivered about 59.2 visible FPS while the panel
  scheduler remained about 119.9 Hz.
- The direct receive source consumes at most two queued drawables per main
  queue invocation. This bounded catch-up removed sequence gaps without
  starving `MTKView` display ticks.
- Focused direct windows lease pacing authority so redundant WindowServer
  work returns to a 100-ms desktop cadence while the iOS panel remains 120 Hz.
- Retina modes are `Standard` (1.0) and `Larger UI` (1.25). Removed 125/150%
  legacy modes must normalize to Standard. “More Space” was rejected because
  it made UI smaller, opposite to the requested behavior.
- Exact unbounded AppKit windows can grow beyond the virtual `NSScreen`; real
  application min/max/aspect/increment constraints still apply. Transient and
  genuinely bounded windows keep native AppKit constraints.
- `UIApplication.supportsMultipleScenes` is not proof of independent floating
  windows: runtime on iPad14,5 / iPadOS 16.0 / 20A8372 created a `678x1024`
  Split View column for a second requested Scene. Treat iPadOS earlier than
  16.1 as non-Chamois. On later systems, create an additional Scene only when
  SpringBoard's real `isChamoisWindowingUIEnabled` calculator argument has
  published `Known|Active`; otherwise reuse the current Scene. The M1 / 20D67
  compatibility witness is `1790883210.214 ... known=YES active=YES`.
- Floating-Dock avoidance must publish the corrected center in the exact
  authoritative resize transaction: the `center:` argument passed into
  `SBItemResizeGestureSwitcherModifier`'s response constructor for a native
  gesture, or the immutable `SBDisplayItemLayoutAttributes` carried by a
  programmatic transition. A frame-only change is non-authoritative, and even
  an immutable clone returned only from the later whole-stage calculator is
  transient: runtime log `1790877358.160` computed `y=24` for the current
  `1179x814` model while the user still saw the persistent `y=78` placement.
  Validate center and unchanged size before publishing; if the full size
  cannot coexist, retain the native floating-Dock behavior assertion instead
  of adding a maximum-height constraint. Its
  `invalidateWithCompletion:` lifecycle is asynchronous: retain the exact
  assertion until completion and serialize release/reassert decisions. The
  `1790879379.516` to `1790879381.080` trace caught duplicate same-Scene
  assertions when the old code dropped ownership before completion.

Input and interoperability:

- Input records carry source, sequence, PID and exact window identity. Do not
  collapse software toolbar, hardware keyboard and global pointer routes.
- iOS IME owns marked-text composition. Only committed Unicode is encoded and
  delivered to the exact AppKit window while preserving its first responder.
- Software-toolbar arrows and modifier chords stay on exact AppInput routing;
  the toolbar's own keyboard-down button dismisses UIKit input. Narrow windows
  reserve a trailing safe lane for the iPad input-method controls.
- While the iOS IME proxy is first responder, physical Magic Keyboard
  navigation and Control/Command chords route to macOS; printable composition
  remains with UIKit, and Command-Tab/Command-Space remain iPadOS shortcuts.
  The source/RE contract is verified; do not claim a final physical-key
  acceptance beyond the dated evidence.
- Windowed physical keys with an exact PID/window belong to that process's
  AppInput endpoint; only window-zero/global hardware input uses the OSXvnc
  session proxy. Runtime on iPad14,5 measured broker/proxy transport below
  about 3.1 ms, while Unity 2022.3.62f2 drained ordinary AppKit-posted events
  in `81-1003ms` batches. The exact 7DTD route may post from the game's own
  CGS connection, but it is not accepted until the dated evidence contains a
  prompt `app-cgs-post -> app-dispatch` physical W/A/S/D and Shift witness.
- Electron/Catalyst precise scrolling no longer performs a synchronous global
  WindowServer hit test for every continuation event. Begin-time ownership
  validation remains; this is route-based, not a VS Code bundle-ID exception.
- Text, rich clipboard representations, files and cross-app drag use bounded,
  versioned payloads with origin/generation and path validation.

Power, heat and memory:

- Do not lower frame rate as the first response to heat. Profile producer,
  receipt, submit, completion, panel tick, CPU, power and thermal state to find
  duplicated work or blocking operations.
- Background/occluded Scenes suspend their streams and status polling.
  MacWSHost leaves the iOS idle timer enabled. `macwshostd` observes the real
  lock state, publishes workspace sleep/wake, and pauses the macOS display
  completion boundary while locked.
- Idle scenes use event-driven/latest-state delivery and a 100-ms idle
  completion cadence. Close TestUFO/Aquarium/video pages after every run;
  multiple hidden benchmarks are real workload, not harmless tabs.
- Release stale direct surfaces, retired Scene controllers, old process
  generations and graphics pools. Do not interpret cached/reclaimable RAM as a
  leak without allocation ownership and time-series evidence.
- The five-minute watchdog records thermal state and temperature and
  intervenes only at `critical`. The retired free-memory percentage guard must
  not return; iOS/XNU memorystatus is the reclamation authority.
- Power A/B comparisons require comparable starting thermal state, charging
  state, workload, duration and visible output. A hotter run at a different
  DVFS point is not a valid energy comparison.

Application-specific memory:

- VS Code/Electron has exact adapters for address-space/JIT/W^X constraints,
  GPU rendering, audio and lifecycle. The current Code Mode host V8 crash is
  fixed at the exec boundary by injecting the existing page-granular W^X
  contract only into the exact `codex-code-mode-host` basename. The fixed
  framed protocol executes JavaScript; this is not an abort/FatalOOM bypass.
- Steam's client/CEF, semaphores, cache ownership and lifecycle have scoped
  adapters. A Steam UI success is not proof that every game works.
- Stock 7 Days to Die app 251570 is x86_64 beyond just its launcher. iOS 16.0
  lacks the kernel translated-task/Rosetta contract; successful `oahd` AOT
  generation does not make x86_64 `exec` work. Do not pursue QEMU/binfmt as if
  it were an installed drop-in solution.
- The tested 7DTD path uses the exact Unity 2022.3.62f2 arm64 player with the
  game's data. M2 startup/title presentation reached about 116 FPS, Shift
  stress and the 48-kHz audio ring passed, and duplicate players are reused
  rather than relaunched. This is not an in-world M2 MacBook-equivalent FPS
  claim. The iPad14,5 one-time 0.35 dynamic-scale profile is exact-device
  gated and must not alter M1 preferences.
- Office, Maps, Settings, Weather, Finder, Terminal, Activity Monitor, Steam,
  VS Code and several other workloads have dated evidence. Do not generalize
  that to a new version or to unrecorded apps such as Edge/Asobi without a
  fresh visible-output and interaction witness.

### Non-negotiable agent workflow

For every new device, OS build, app version, feature or regression:

1. **Inventory without mutation.** Record `hw.machine`, iPadOS version/build,
   jailbreak/trustcache tools, macOS `ProductVersion`/`ProductBuildVersion`,
   rootfs mount, free space, target Mach-O architectures, UUIDs and hashes.
2. **Preserve a baseline.** Reproduce one bounded scenario and copy the exact
   crash/log/profile excerpt. Stop duplicate apps, old benchmark tabs and
   orphan `grep`, `tail`, `sample`, `oslog` or debugger jobs before measuring.
3. **Separate FACT from THEORY.** A source comment is not runtime evidence;
   uptime is not visible output; a successful build is not device acceptance.
4. **Find the producing layer.** Trace backwards from the invalid state to the
   operation that should have created/populated/retired it. Never start with a
   NOP, forced branch, blanket constant return or zero-filled fake object.
5. **RE the exact binary when private ABI is involved.** Match UUID/hash,
   preserve the disassembly and validate every patched instruction before
   writing. Unknown identities must fail closed.
6. **Run a one-variable A/B.** Instrument bounded counters/timestamps; avoid
   logging per frame in production. Preserve rejected hypotheses in a dated
   evidence note so another agent does not repeat them.
7. **Implement the narrow upstream invariant.** Prefer capability, route,
   class, geometry, exact path, UUID or protocol-version gates over bundle-ID
   special cases. Diagnostics must default off and must not be prerequisites.
8. **Test locally.** Run focused tests, the full `misc/test_*.py` suite when
   feasible, runtime-switch audit, protocol tests, `bash -n` for changed shell
   scripts and `git diff --check`.
9. **Build the affected architectures.** `libmachook` requires both arm64 and
   arm64e thin installed images. SpringBoard code requires the validated
   Apple-ld64 artifact; an on-device lld result is not interchangeable.
   MacWSWindowing must also carry the rootless
   `@rpath/CydiaSubstrate.framework/CydiaSubstrate` load command. A rootful
   `/Library/Frameworks/...` dependency passes signing and fixup checks but is
   runtime-confirmed to make ElleKit omit the tweak.
10. **Deploy through the project pipeline.** Verify source hashes and installed
    artifacts. Avoid direct in-place `scp` over a signed dylib: reusing the
    vnode can leave the kernel's code-signature cache stale.
11. **Accept on visible/protocol output.** Require the appropriate pixels,
    sequence advance, input result, XPC response, audio callback or other real
    endpoint. Recheck crash reports and thermal state.
12. **Clean up.** Close generated webviews, stop finite samplers, remove only
    explicitly scoped diagnostic markers and ensure no debug process remains.
13. **Document and synchronize.** Add/update a dated evidence file, tests and
    runtime-switch inventory. Keep this repository and `../macPad` aligned for
    shared files, then commit and push each repository separately.

### New-device/version porting checklist

Useful read-only inventory commands (replace placeholders; never commit
credentials):

```bash
ssh -p <port> <user>@<device> 'uname -a; sw_vers 2>/dev/null || true; sysctl hw.machine kern.osversion'
ssh -p <port> <user>@<device> 'ls -l /var/jb/usr/bin/jbctl /var/mnt/rootfs/System/Library/CoreServices/SystemVersion.plist'
ssh -p <port> <user>@<device> 'file /var/mnt/rootfs/path/to/target; otool -l /var/mnt/rootfs/path/to/target | grep -A5 LC_UUID'
```

Then build a compatibility matrix before editing:

- device model/SoC, iPadOS version and build;
- jailbreak and whether live CDHashes can be admitted;
- macOS rootfs version/build and target architecture slices;
- WindowServer, SpringBoard, Metal/AGX, MTLCompilerService and app UUIDs;
- display pixel/point size and maximum refresh rate;
- working baseline for CLI, WindowServer, exact-window display, input and
  recovery.

Port hardcoded patches by semantic function and validated instruction window,
not by adding a broad OS-version conditional. Keep the previous identities in
the allowlist and run a regression on the older device before declaring the
new target supported.

### Build, deploy and recovery shortcuts

For an already prepared device tree, prefer the content-verified pipeline:

```bash
MACWS_DEVICE=<user@device> \
MACWS_DEVICE_PORT=<port> \
MACWS_SUDO_PASSWORD=<temporary-password> \
bash misc/device_pipeline.sh --component libmachook

# Complete package and bounded workspace restart when the change crosses
# package/plist/daemon boundaries:
MACWS_DEVICE=<user@device> MACWS_DEVICE_PORT=<port> \
MACWS_SUDO_PASSWORD=<temporary-password> \
bash misc/device_pipeline.sh --component full --restart-workspace
```

Components are `runtime`, `display`, `input`, `workspace`, `host`, `hostd`,
`compiler`, `libmachook`, `metal`, and `full`. Choose the smallest component
that contains the change; use `full` when a package payload, launch job,
SpringBoard tweak, dependency or postinstall contract changed.

Representative local gates:

```bash
python3 -m unittest discover -s misc -p 'test_*.py'
python3 misc/audit_runtime_switches.py
cc -std=c11 -Wall -Wextra -Werror -Iinclude \
  misc/macws_protocol_test.c -lm -o /tmp/macws_protocol_test
/tmp/macws_protocol_test
bash -n misc/device_pipeline.sh misc/cleanup_all.sh \
  layout/usr/macOS/bin/macos_gui.sh
git diff --check
```

Runtime control:

```bash
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh production
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh status
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh restart coexist
sudo bash /var/jb/usr/macOS/bin/macos_gui.sh stop
```

Emergency cleanup after a crash loop or abandoned profiling session:

```bash
sudo bash /var/jb/var/mobile/MacWSBootingGuide/misc/cleanup_all.sh
```

Large rootfs archives should remain compressed while stored on archival/NAS
disks. Do not unpack millions of small files onto a slow archival volume.
Prefer a direct resumable rsync 3.x transfer using
`--partial --append-verify --info=progress2` to suitable target/staging
storage, verify the archive hash, and unpack on the device or SSD-backed
filesystem. Apple's bundled openrsync 2.6.9 lacks those exact options. A relay
Mac may stream the transfer without extracting locally. Never put Apple
rootfs/framework payloads in Git.

### Performance and profiling contract

Use `misc/macws_frame_power_profile.py` for sustained display/power work and
`misc/macws_ui_profile.py` for gesture/input scenarios. A valid 120-Hz claim
counts unique producer sequences that reach the real Host drawable-presented
callback; repeatedly presenting one old IOSurface does not count.

Before every scored run:

- require a known target PID/window and a single foreground workload;
- start at a recorded thermal state, preferably `nominal`;
- close other TestUFO/Aquarium/video/game instances;
- use a finite sampler and an automatic cleanup command;
- capture producer/Host cadence, latency distributions, retention, command
  errors, process CPU deltas, power/temperature and boundary RSS/IOSurface;
- compare like-for-like resolution, quality, charging and thermal conditions.

After every run, verify the cleanup command succeeded and inspect the process
list. A forgotten benchmark or recursive log scan can materially heat the
device and invalidate the next result.

## Imported Project-Memory Ledger (complete audit: 2026-10-01)

The former per-agent project memory directory contained one index and four
topic files: macOS build SDK setup, Claude Code in the iOS chroot, the chroot
SOCKS proxy, and autosignd on-demand signing. This section carries every
durable fact from those files into the repository. It is intentionally
self-contained: do not depend on a private agent memory store or resurrect
the old cross-references. Where a 2026-06 observation is historical, that is
stated explicitly; current source and current build outputs take precedence.

### autosignd on-demand signing (introduced 2026-06-11)

AMFI checks each `exec` in the kernel and kills a Mach-O whose CDHash is not
admitted. Trustcache mutation must run in an iOS-platform process. A macOS
process inside the chroot cannot call the jailbreak trust API directly because
macOS dyld rejects the iOS `libjailbreak.dylib` with `incompatible platform:
have 'iOS', need 'macOS'`. That is why signing is split across the chroot and
an iOS-native daemon rather than implemented wholly in `libmachook`.

- `autosignd/main.c` is an iOS/arm64 daemon. It listens at the host path
  `/var/mnt/rootfs/tmp/autosignd.sock`, which is `/tmp/autosignd.sock` inside
  the chroot. For each requested chroot path it prepends `/var/mnt/rootfs`,
  runs `ldid -S<entitlements> -M`, extracts every present architecture's
  CDHash, and admits each hash with `jbctl trustcache add`. An in-memory seen
  set avoids repeated work. `postinst.sh` starts/restarts it and its historical
  log location is `/var/mnt/rootfs/tmp/autosignd.log`.
- `libmachook/exec_hooks.c` interposes `posix_spawn`, `posix_spawnp`,
  `execve`, `execv`, and `execvp`. A bare executable is first resolved through
  `PATH`; the hook sends its chroot path to autosignd, waits up to five seconds
  for `OK`, then executes. The signing request is fail-open so an unavailable
  daemon does not replace the real `exec` error. Each process keeps a
  mutex-protected path cache. The `execl*` varargs forms normally enter the
  covered array forms in libsystem.
- Do not obtain an interposed original with `dlsym(RTLD_NEXT, ...)` here. That
  returned NULL and caused a segfault. Under `DYLD_INTERPOSE`, call the symbol
  directly (for example `execve(...)`); dyld does not re-interpose the
  interposing image's own call. `os_log_hooks.m` uses the same contract.
- Always ad-hoc re-sign with the project entitlements before adding the
  CDHash. Trustcaching the existing Apple signature alone was runtime-tested
  and still produced an AMFI SIGKILL because platform/library-validation state
  remained incompatible. Re-sign plus trustcache ran successfully.

The original end-to-end witness was a previously untrusted chroot binary that
became signed and executable on first launch; autosignd also logged live child
signing for tools such as `ps`, `bash`, `ioreg`, and `grep`. Keep this as the
semantic contract, but revalidate current paths and hashes on a new build.

### Chroot DNS and the self-contained proxy

The chroot can have working IP connectivity while its macOS resolver and
Security/Keychain services are unreachable, producing `Could not resolve
host`. Proxy environment variables are useful only if an actual listener is
running. A historical self-contained setup made the iOS device SSH to its own
sshd and exposed a dynamic forward on loopback:

```bash
# One-time on the device: create a device-local key and authorize only that key.
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys

# Example only: use the device's actual local sshd port.
ssh -f -N -D 127.0.0.1:1082 -o BatchMode=yes \
  -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 -p <LOCAL_SSH_PORT> root@127.0.0.1
```

Use `ALL_PROXY=socks5h://127.0.0.1:1082` for tools that support SOCKS. The
`h` is load-bearing: DNS is resolved by the proxy/iOS side; `socks5://` leaves
DNS in the broken chroot. Verify the listener with a bounded `curl` through
`socks5h`, not with iOS `netstat`, which was unreliable in this environment.
Starting `ssh -f` from inside another SSH session can keep the parent waiting
because inherited descriptors remain open even though the dynamic forward is
already bound.

Claude Code's undici client does not use a SOCKS proxy for its own API egress.
It needs an `http://`/`https://` proxy whose upstream resolves DNS, such as a
mixed HTTP-and-SOCKS `pproxy` listener. Claude's separate
`CLAUDE_CODE_HOST_SOCKS_PROXY_PORT` is for sandboxed children and does not
provide the parent client's egress.

### Claude Code inside the macOS chroot (historical verified recipe)

The native bun/JSC Claude Code binary was verified in this environment on
2026-06-11 with version 2.1.170, then a roughly 222-MB single-architecture
`darwin-arm64` Mach-O. That size/version is a historical witness, not a claim
about the current release format.

- The official installer rejected the chroot because `uname -m` reported the
  iPad model identifier rather than `arm64`. The working installation path was
  to read the release version endpoint and `manifest.json`, select the
  `darwin-arm64` artifact and its SHA-256, download it directly, verify the
  hash, install it at `/usr/local/bin/claude`, and mark it executable.
  Python 3.13 was used for JSON and hashing because chroot `jq`/`shasum`
  wrappers could hit the AMFI shebang constraint.
- Sign and trustcache the binary and every native helper it spawns. The
  historical manual command was `ldid -S<project-entitlements> -M <binary>`
  followed by admission of each slice's CDHash; autosignd now owns the normal
  first-exec path.
- JSC initially attempted a 64-GiB gigacage virtual-address reservation and
  aborted. Export `GIGACAGE_ENABLED=0`; increased-memory/extended-VA
  entitlements did not solve it. Do **not** set `BUN_JSC_useGigacage`: bun
  rejected that as an invalid JSC environment variable.
- `claude -p` initially failed `posix_spawn('/usr/bin/security')` with
  `EBADEXEC`/errno `-85`. Re-signing and trustcaching the fat arm64e+x86_64
  `/usr/bin/security` allowed Claude to fall back to file credentials.
  `postinst.sh` historically covered both `claude` and `security`, while the
  chroot `.bashrc`/`.bash_profile` exported the TUI environment. Confirm those
  source paths before assuming a fresh rootfs still has the block.
- Its API client accepts HTTP(S), not SOCKS, proxy URLs. The chroot still has
  no resolver, so the HTTP proxy must resolve on the upstream side. The
  historical test found `SSL_CERT_FILE` did not affect Claude's own request,
  but the standard chroot environment retains `/etc/ssl/cert.pem` because
  other tools do require it.
- Authentication can be supplied without `settings.json`:
  `ANTHROPIC_API_KEY` selects `x-api-key`; `ANTHROPIC_AUTH_TOKEN` together
  with `ANTHROPIC_BASE_URL` selects bearer authentication for a relay. An
  internal gateway must not be sent through an unrelated external proxy: add
  a fixed host mapping plus `NO_PROXY`, use a proxy with internal egress, or
  choose the correct base URL. The historical dummy-key checks distinguished
  `Not logged in` from `Invalid API key`, proving the variables were read.

`claude --version` and `--help` are installation checks only. A real prompt
still requires an API credential or interactive `/login` and working browser/
network routing. The minimal run environment includes the explicit chroot
`PATH`, `HOME=/Users/root`, `SSL_CERT_FILE=/etc/ssl/cert.pem`,
`GIGACAGE_ENABLED=0`, and the appropriate proxy variables.

### macOS cross-build SDK setup (2026-06 history plus current rule)

The host build already used `gmake`, `ldid`, Python, codesign, SSH/SCP and a
Theos checkout. Installing Homebrew `dpkg` or `fakeroot` was unnecessary:
Theos's `bin/dm.pl`, `bin/fakeroot.sh`, and `GO_EASY_ON_ME=1` provide package
creation.

Two non-obvious SDK fixes were committed into the repository:

1. The Theos iPhoneOS 16.5 SDK lacked `usr/include/xpc/`, although
   `MTLSimDriverHost` and `libmachook` include `<xpc/xpc.h>`. The repository
   vendors the needed headers under `vendor/ios-xpc/xpc/` and adds
   `-isystem $(CURDIR)/../vendor/ios-xpc` to the affected subprojects.
   `session.h` and `listener.h`, and their includes from `xpc.h`, were removed
   because they require the newer `OS_OBJECT_DECL_SENDABLE_CLASS` macro from
   iOS 17/macOS 14 rather than the target 16.5 SDK. See the vendored README.
2. `launchservicesd` uses a macOS target, while Theos searches its platform SDK
   directory and `$THEOS/sdks`, not the Command Line Tools SDK directory.
   `misc/build.sh` locates the active CLT/Xcode SDK and version via `xcrun` and
   symlinks it into `$THEOS/sdks` when no macOS SDK is available there. The
   rejected alternative was compiling this boot-critical loader as iOS and
   rewriting its platform tag afterward; keep the native macOS target.

The obsolete `login` subproject was removed because it duplicated
`launchdchrootexec`'s bash-spawn path and was never executed; its Makefile,
postinstall trustcache entry, and directory were deleted. The memory recorded
five root subprojects at that time and a hard-coded deploy target in the old
`build.sh`. Both are historical implementation details. Always inspect the
current root `SUBPROJECTS` and the current parameterized build/deploy scripts;
never restore a user-specific destination or treat the old count as current.

## Historical AGX Bring-up Snapshot (not the current project goal)

The following section records an early direct-AGX blocker investigation. It
is retained to prevent repeated dead ends, but later milestones solved the
production rendering path. Do not infer from its phrase “only remaining
viable path” that a full per-call Metal XPC proxy is the current architecture.
The current architecture and acceptance rules are described above and in
`docs/displaystream-host-architecture.md`, `docs/metal2metal.md`, and the
dated evidence tree.

**Goal:** Run macOS WindowServer in chroot on jailbroken iPad13,6 (iOS
16.3 arm64) using **real iOS AGX kernel driver only**
(`MACWS_AGX_NATIVE=1`). Verify via VNC screen capture that **GlassDemo
renders fully** — title bar, controls, AND **blur**
(`NSVisualEffectView` vibrancy / backdrop blur) — none of which work
fully under the MTLSim path.

### Why NOT the SIM path

Confirmed gaps (memory: `backdrop-blur-tile-pipeline-blocked`):

- MTLSimDriver's `newRenderPipelineStateWithTileDescriptor` is a
  `MTLReportFailure` stub → tile pipelines unavailable.
- QuartzCore's `BlurState::tile_downsample` returns no output →
  NSVisualEffectView vibrancy renders pure black.
- Complex GPU-heavy apps (Firefox WebRender / Chrome) hit the same
  modern-Metal-feature gaps and can't render.

### What works under AGX-native today (runtime-confirmed)

- Cross-image ObjC class preregistration (`_dyld_image_count` walk +
  `objc_readClassPair` per image with `__objc_classlist`) — AGXBuffer
  + 51 other AGXMetal13_3 classes register. Log:
  `PREREGISTER image[308] AGXMetal13_3: 52/52 realized`.
- `-[AGXG13GFamilyDevice setupCompiler:]` runs to completion. Log:
  `MACWS_AGX_NATIVE setupCompiler:0x30010 fired (Device=…)`.
- `setupDeferred` dispatch_once block reaches `Mempool::grow` and
  iterates the lambda 6+ times per session without crashing.
- 4-arg `-[IOGPUMetalResource initWithDevice:options:args:argsSize:]`
  swizzle catches the BL site lldb-traced inside
  `AGX::Heap<true>::allocateImpl` block_invoke at `0x1e5a4d628`.
- `macwsallocd` (iOS-native launchd daemon,
  `com.macwsguide.alloc`) allocates 256 MB IOSurfaces and ships
  mach-ports to chroot. ~10-15 IOSurface round-trips per WS start.
- Synthesized AGXG13GFamilyBuffer via bare-alloc + associated-object
  tagging + class-wide swizzles on `-resourceSize` / `-length` /
  `-contents` / `-virtualAddress` / `-gpuAddress` / `-device` returns
  the IOSurface-derived values when tagged.
- `ivar+0x30 = calloc(16K)` per buf satisfies Mempool::grow's
  freelist init without libmalloc heap corruption (using IOSurface
  base there triggers `free_list_checksum_botch` on dealloc — RE +
  runtime confirmed).
- AGXIOC sels 0x0, 0x2, 0x4, 0x5, 0x21, 0x25, 0x100, 0x102, 0x107 all
  succeed against the chroot's user-client (these are read/query/info
  methods — they don't need the privileged init state).

### Structural blockers (RE-confirmed, NOT theories)

| # | Failing op | RE evidence | Root cause |
|---|---|---|---|
| 1 | `IOConnectCallMethod sel=0xa→0x9` (heap create) | kernel returns `0xe00002c2 = kIOReturnNoBandwidth`. The two reject sites inside `IOGPUDevice::new_resource` (`+0x44` checking `(IOGPU+0x224)+0x50 vs *outCnt`, and `+0xff` checking `args+0x40 vs (3*IOGPU+0x108/4)`) BOTH pass for our calls: `misc/agx_iogpu_probe` runtime measured `IOGPU+0x108 = 0x139ce0000` (5.13 GB) and `IOGPU+0x224 = 0` against the singleton at `0xfffffe690002c000` (same kernel object for chroot and iOS-native). | **Reject site is elsewhere in `IOGPUFamily`** — RE in progress to find which path returns 0xe00002c2 (candidates: per-task wire/pin limit, IOMemoryDescriptor::prepare on the backing memory, or a higher-up dispatch check). `MACWS_AGXIOC_FUZZ=1` confirms NO args-shape perturbation succeeds → the gate doesn't look at args at all. |
| 2 | `IOConnectCallMethod sel=0x7→0x6` / `sel=0x8→0x7` (queue create) | `inSC=1032` hex dump captured via libmachook `IOConnectCallMethod_new` one-shot dumper. macOS userland packs process path string at offset 0; iOS-native `_IOGPUCommandQueueCreateWithQoS+0xaf0` (otool disasm of `~/Downloads/agx-re/ios/IOGPU`) zeros the buffer then writes QoS at `+0x400` / priority at `+0x404`. Patched IOConnect translator to substitute iOS-shape buffer → kernel STILL returns `0xe00002c2`. | Same UC-init root cause as #1. |
| 3 | Borrow io_connect_t from iOS-native helper via XPC | Standalone borrow test runtime log (no chroot WS in loop): macwsallocd opens UC OK → `set_mach_send completed` → `about to send_message` → SIGKILL'd. Crash report `EXC_GUARD ILLEGAL_MOVE on mach port`. | `io_connect_t` mach ports are first-class GUARDED by IOKit at the kernel-port level. `mach_msg` transfer of the send-right trips the kernel guard. **Structural — the user-client port cannot cross task boundaries.** |
| 4 | SkyLight compositor needs non-nil queue | `CAWSBackend.mm:5130 — Assertion failed: (compositor != nullptr)`. BT chain via lldb: `setupDeferred → newCommandQueue` (queue alloc'd via sel=0x7/0x8 which return nil). | Downstream of #2. |
| 5 | Compositor missing means no rendering | VNC framebuffer all-zero PNG (`md5` confirmed identical across multiple grabs from `vncdo capture`); chroot `screencapture -x` also all-zero. WS process can stay alive (no crash log) but produces no display output. | Downstream of #4. |

### What this rules out (saved from repeating)

| Approach | Status | Why ruled out |
|---|---|---|
| Add more entitlements | ❌ Disproved | backboardd (works) has only 2 GPU-private entitlements: `allow-explicit-graphics-priority`, `graphics-restart-no-kill`. Our `entitlements.plist` already has both. |
| Re-sign binary with iOS team-id | ❌ Disproved by RE | `IOGPUDeviceUserClient::externalMethod` at `0xfffffe0009eed344` (capstone) has no entitlement-string check or task-credential check in the dispatch path. |
| `IOServiceOpen` type variations | ❌ Disproved | Tested `type=0`, `type=2`, `type=1` (mask of `0x100001`), and `0x100001` raw — all give same broken UC. `MACWS_AGX_FORCE_TYPE` env var exists for further fuzzing. |
| `IOConnectCallMethod` args shape patch | ❌ Disproved | `MACWS_AGXIOC_FUZZ=1` perturbed every reachable byte; all 10 perturbations fail same code. |
| Borrow opened io_connect_t from helper | ❌ Disproved this session | EXC_GUARD ILLEGAL_MOVE; see blocker #3. |
| Synth buffer via `pinnedGPULocation:` in chroot | ❌ Disproved | `pinnedGPULocation:` also routes through sel=0xa internally → same kernel rejection. Verified: pin5 call hangs the chroot thread. |

### Historical proposed path (not current; retained to explain a rejected direction)

**Full Metal proxy**: chroot serializes every `MTL*` operation
(`setBuffer/setTexture/setRenderPipelineState/draw…/blit*/commit`) →
XPC to a new helper running in iOS-native context (sees real AGX) →
helper replays on a real iOS `MTLCommandQueue` → returns IOSurfaces
back.

Open architectural risks (must be considered before committing):

- **Performance** — typical SkyLight frame = 500-2000 encoder calls.
  At ~10-50 µs/XPC roundtrip, 60 fps budget (16.7 ms) is overrun 1-4×.
  Static scenes likely OK; interactive/scrolling not.
- **`MTLDrawable` / `CAMetalLayer` cross-process** — display
  submission may not be proxyable; if not, no on-screen pixels.
- **`MTLLibrary` / pipeline state per-device binding** — chroot-built
  libraries won't directly run in helper's device; may require
  AIR-source re-ship + re-compile, slow.
- The architecture is **NOT** strictly "AGX native from chroot" —
  chroot itself never directly touches AGX. It's an iOS-native AGX
  execution bridge. Same shape as MTLSim path, just with a self-built
  proxy instead of Apple's MTLSim.

### Recovery: one-click stop of all chroot services

When CPU/load gets stuck due to a crash loop, build-helper zombies, or
orphan debug tools, **don't keep restarting WS** — that just keeps the
loop alive. Run the project's recovery script:

```bash
sudo bash /var/jb/var/mobile/MacWSBootingGuide/misc/cleanup_all.sh
```

It stops the GUI stack, unloads all `com.macwsguide.*` launchd jobs,
kills WindowServer / launchservicesd / OSXvnc-server / macwsallocd /
autosignd / launchdchrootexec / orphan oslog / tail / find_crash from
debug sessions, then prints the final state. Bounds damage from a
runaway loop to ~10 seconds of high CPU.

## Build

This project uses [Theos](https://theos.dev).

### Build on iOS (on-device) via SSH

Theos is installed at `/var/jb/var/mobile/theos`. The project lives at
`/var/jb/var/mobile/MacWSBootingGuide`. SSH does **not** inherit `THEOS` from
the device's interactive shell, so pass it explicitly:

```bash
# From macOS, over SSH (one-liner):
ssh -p <SSH_PORT> mobile@<DEVICE> \
  'THEOS=/var/jb/var/mobile/theos bash /var/jb/var/mobile/MacWSBootingGuide/misc/build_on_ios.sh'
```

`build_on_ios.sh` does: clean → make → package → dpkg install → set macOS
build version → fix arm64e interpose section → re-sign → postinst.

After a successful build, verify with:
```bash
ssh -p <SSH_PORT> mobile@<DEVICE> 'sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c "echo hi"'
# Expected output: "chdir: No such file or directory" (harmless), then "hi", exit 0
```

Git operations over SSH fail due to host-key policy; use `git reset --hard
origin/main` to sync (fetch works with HTTPS, push does not from device).

### Build on iOS (on-device) manually

```bash
# On the device shell with THEOS set:
export THEOS=/var/jb/var/mobile/theos
cd /var/jb/var/mobile/MacWSBootingGuide
make FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless GO_EASY_ON_ME=1 package
sudo dpkg -i packages/*.deb

# Required: patch LC_BUILD_VERSION from iOS → macOS 13.0; macOS dyld rejects iOS platform tag
sudo python3 misc/set_macos_version.py /var/jb/usr/macOS/lib/libmachook.dylib

# Required: re-sign after binary was modified above
sudo ldid -S /var/jb/usr/macOS/lib/libmachook.dylib

sudo bash /var/jb/usr/macOS/bin/postinst.sh
```

### Build on macOS (cross-compile)

```bash
gmake FINALPACKAGE=1 STRIP=0 THEOS_PACKAGE_SCHEME=rootless package install \
  THEOS_DEVICE_IP=<device_ip> THEOS_DEVICE_PORT=2222 GO_EASY_ON_ME=1
```

After install, on the device:
```bash
sudo bash /var/jb/usr/macOS/bin/postinst.sh
```

The repository now has focused unit/contract tests under `misc/`. Run the
focused test for the changed subsystem first, then the complete suite when
feasible. Runtime investigation still commonly uses:
```bash
sudo oslog | grep "AMFI\|debugbydcmmc\|launchd\|launchser\|WindowSer\|MTL\|Metal\|Terminal\|iolation"
```

## Architecture

### Subprojects

The root `Makefile` is the aggregate build entry point for the iOS host,
daemons, tweaks, injected macOS compatibility layer, launch helpers and shared
protocol code. The historical core groups are described below; inspect the
current `SUBPROJECTS` value before assuming the list is exhaustive.

**iOS-side (run in iOS context):**
- `MTLCompilerBypassOSCheck/` — CydiaSubstrate tweak that patches `MTLCompilerService` platform checks so it will compile Metal shaders for a macOS (non-iOS) target.
- `MTLSimDriverHost/` — XPC service that hosts `MTLSimDriver.framework` (from the iOS Simulator runtime). Bridging macOS Metal calls to the iOS GPU driver.
- `launchdchrootexec/` — Small iOS binary that chroots into the macOS rootfs and execs a macOS binary with `DYLD_INSERT_LIBRARIES` pointing to `libmachook.dylib`.
- `autosignd/` — iOS-side daemon that signs + trustcaches Mach-O binaries on demand. `libmachook`'s exec hooks ask it (over a unix socket) to ad-hoc re-sign + trustcache each binary just before it is `exec`'d, so arbitrary macOS programs run in the chroot without pre-listing every binary in `postinst.sh`.

**macOS-side (compiled for macOS target, run inside the chroot):**
- `libmachook/` — The core dylib injected into every macOS process. Contains all runtime interposition hooks.
- `launchservicesd/` — Loader that converts the macOS `launchservicesd` daemon into a dylib so it can run without entitlements that would cause a codesign panic.

### libmachook — Core Hook Library

`libmachook/mac_hooks.m` is the primary file. It registers a `dyld_register_func_for_add_image` callback (`loadImageCallback`) that fires for every loaded image and applies binary patches by scanning for specific byte sequences at runtime (hardcoded for iOS 16.5 / macOS 13.4).

Key patches applied:
- **SkyLight** — Removes backboardd coexistence check.
- **IOMobileFramebuffer** — Fixes kernel parameter passing for the iOS framebuffer.
- **Metal** — Bypasses extra MTL reflection deserialization; patches `sysctlbyname` to spoof OS version (reports iOS 16.x as macOS 13.x).
- **libxpc** — Registers `MTLCompilerService` bundle for the XPC lookup.
- **Sandbox** — Disables `sandbox_init_with_parameters` (returns 0).
- **Audit tokens** — Stubs `audit_token_to_asid`, `audit_token_to_auid`, `auditon`, `getaudit_addr` (missing on iOS).
- **Mach ports** — Patches `mach_port_construct` to remove invalid flags.

Additional hook files in `libmachook/`:
- `Metal_hooks.x` — Hooks `MTLSimDevice` and `MTLSimBuffer` to fix storage mode mismatches and `vm_remap`-based XPC memory sharing.
- `QuartzCore_hooks.x` — Skips unsupported tile render pipeline calls.
- `jit.m` — Enables JIT (MAP_JIT) for the process.
- `objc_hooks.c` — ObjC runtime patches.
- `os_log_hooks.m` / `os_variant_hooks.x` — Logging and OS variant spoofing.

### File Syntax

`.x` files use [Logos](https://theos.dev/docs/logos-syntax) (Theos hooking preprocessor). Key directives:
- `%hook ClassName` / `%end` — Hook an Objective-C class.
- `%orig` — Call the original implementation.
- `%ctor` / `%dtor` — Constructor/destructor.

### Hardcoded Offsets

Many patches in `mac_hooks.m` search for hardcoded byte sequences to locate patch sites. These are specific to **iOS 16.5 / macOS 13.4**. When porting to new OS versions, these byte patterns need to be re-derived.

### Entitlements

`entitlements.plist` contains 100+ entitlements required for direct kernel/GPU/hardware access. Every macOS binary run inside the chroot must be re-signed with this plist: `ldid -S./entitlements.plist -M <binary>`.

### Required External Frameworks

Must be sourced from the iOS Simulator runtime (not included in this repo):
- `MTLSimDriver.framework`
- `MTLSimImplementation.framework`
- `MetalSerializer.framework`

### Running Binaries in the macOS Chroot

Before any macOS binary can run on the device, it must be re-signed and its CDHash registered in the trustcache:

```bash
# Re-sign with required entitlements
ldid -S/var/jb/usr/macOS/bin/entitlements.plist -M /var/mnt/rootfs/path/to/binary

# Register CDHash(es) — repeat for each slice you need
cdhash=$(ldid -arch arm64 -h /var/mnt/rootfs/path/to/binary 2>/dev/null | grep CDHash= | cut -c8-)
jbctl trustcache add "$cdhash"
```

Enter the macOS bash environment interactively (CLI only):
```bash
sudo bash /var/jb/usr/macOS/bin/run_bash.sh
```

Run commands or scripts non-interactively (`run_bash.sh` forwards all arguments to bash):
```bash
# Inline command
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c "echo hello"

# Multi-line script piped via stdin (script lives on iOS filesystem)
# Always set the full environment at the top of every script:
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -s <<'EOF'
# --- standard chroot environment ---
export PATH=/opt/local/bin:/opt/local/sbin:\
/opt/local/Library/Frameworks/Python.framework/Versions/3.13/bin:\
/opt/homebrew/bin:/opt/homebrew/sbin:\
/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/Users/root
export USER=root
export TMPDIR=/tmp
export SHELL=/bin/bash
# Network (DNS routed through SOCKS5h proxy):
export ALL_PROXY=socks5h://127.0.0.1:1082
export HTTPS_PROXY=socks5h://127.0.0.1:1082
export HTTP_PROXY=socks5h://127.0.0.1:1082
# SSL: Security framework is unreachable in chroot; use the system cert bundle:
export SSL_CERT_FILE=/etc/ssl/cert.pem
# --- end environment ---

echo "running in chroot"
port version
python3.13 --version
EOF

# Script file that lives on the macOS rootfs, with arguments
sudo bash /var/jb/usr/macOS/bin/run_bash.sh /tmp/script.sh arg1 arg2
```

Notes:
- `chdir: No such file or directory` always appears on stderr — harmless, falls back to `/`.
- PATH is inherited from the iOS shell; **always override it** in scripts or tools will resolve to iOS procursus binaries which crash inside the chroot (libiosexec sandbox).
- `HOME=/Users/root`, `USER=root`, `TMPDIR=/tmp` are pre-set by `launchdchrootexec` but PATH is not.
- `SSL_CERT_FILE=/etc/ssl/cert.pem` is required for any Python/curl SSL to work — the macOS Security framework (Keychain) is unreachable in the chroot.
- For script files: place them under `/var/mnt/rootfs/` so they are accessible inside the chroot (e.g. iOS path `/var/mnt/rootfs/tmp/script.sh` → chroot path `/tmp/script.sh`).
- After installing software via `port` or `brew`, run `misc/sign_installed.sh` from the iOS shell to sign and trustcache all new Mach-O files (see below).

Start WindowServer and GUI daemons (unloads SpringBoard/backboardd first):
```bash
sudo launchctl unload /System/Library/LaunchDaemons/com.apple.{SpringBoard,backboardd}.plist
sudo launchctl load /var/jb/usr/macOS/LaunchDaemons
```

Inside the chroot shell, run GUI applications:
```bash
/usr/local/bin/OSXvnc-server -rfbnoauth   # start VNC server first
/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
/System/Applications/Utilities/Activity\ Monitor.app/Contents/MacOS/Activity\ Monitor
```

Return to iOS (respring):
```bash
sudo launchctl unload /var/jb/usr/macOS/LaunchDaemons
sudo launchctl load /System/Library/LaunchDaemons/com.apple.{SpringBoard,backboardd}.plist
```

### Device Setup Summary

1. Mount a full macOS filesystem DMG to `/var/mnt/rootfs` with the symlinks described in the README.
2. Patch `dyld`, `launchservicesd`, and `WindowServer` binaries (some manual, some automated by hooks — see README's "Additional patches" section).
3. Run `postinst.sh` to re-sign binaries and register trustcaches via `jbctl trustcache add`.
4. Use `launchdchrootexec` (via launchctl) to start macOS daemons; WindowServer reads display via `IOMobileFramebuffer`.
5. Connect via VNC (`OSXvnc-server`) or interact via the chroot shell.

---

## Practical Knowledge: iOS Shell Operations

### Commands That Require `sudo`

Run these from the iOS shell (SSH or terminal). Almost all privileged operations need `sudo`:

```bash
# Always need sudo:
sudo bash /var/jb/usr/macOS/bin/run_bash.sh          # enter chroot
sudo bash /var/jb/usr/macOS/bin/postinst.sh          # re-sign & trustcache
sudo ldid -S<entitlements> -M <binary>               # re-sign a binary (writes signature)
sudo jbctl trustcache add <cdhash>                   # register CDHash (modifies trustcache)
sudo /var/jb/usr/local/bin/mount_bindfs <src> <dst>  # bind mount
sudo launchctl load/unload <plist>                   # manage daemons
sudo dmesg                                           # kernel log

# Do NOT need sudo (read-only or user-space):
ldid -h <binary>                  # inspect CDHash (read-only)
ldid -arch arm64 -h <bin> 2>/dev/null | grep CDHash= | cut -c8-  # extract cdhash
jbctl trustcache info             # dump trustcache contents (read-only)
ls, cat, grep, file, strings      # read-only inspection
oslog                             # log streaming (may need sudo for kernel logs)
python3                           # iOS procursus python3
```

**jbctl trustcache commands**:
- `jbctl trustcache add <hash>` — requires sudo (modifies trustcache)
- `jbctl trustcache info` — no sudo needed (read-only, dumps all CDHashes)
- `jbctl trustcache list` — **broken**, always returns empty; use `info` instead

Prefer interactive `sudo` or the credential handling in
`misc/device_pipeline.sh`. If automation is unavoidable, pass a temporary
secret through the runner's environment; never put a password literal in a
script, prompt, log, or repository.

### Extracting and Registering CDHashes

```bash
# Sign and register a single binary (all architectures):
ENT=/var/jb/usr/macOS/bin/entitlements.plist
sudo ldid -S"$ENT" -M /var/mnt/rootfs/path/to/binary
for arch in arm64 arm64e x86_64; do
    h=$(ldid -arch "$arch" -h /var/mnt/rootfs/path/to/binary 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$h" ] && sudo /var/jb/usr/bin/jbctl trustcache add "$h"
done
```

---

## Critical Constraint: AMFI Shebang Block

**AMFI kills `execve()` of any file with a `#!/...` shebang line** (exits 126, `EPERM`).
This applies to ALL scripts, not just shell scripts.

**Symptoms**: Command exits immediately with no output; `dmesg` shows `AMFI: ... deny`.

**Workaround — remove shebangs**: When bash tries to exec a file and gets `ENOEXEC` (no
recognized binary/shebang format), it falls back to interpreting it as a shell script directly.
This works for any script executed within a running bash session.

```bash
# Strip the first line if it's a shebang (iOS-side, using python3 — NOT GNU sed):
python3 -c "
import sys
with open(sys.argv[1], 'r+') as f:
    lines = f.readlines()
    if lines and lines[0].startswith('#!'):
        f.seek(0); f.writelines(lines[1:]); f.truncate()
" /var/mnt/rootfs/path/to/script
```

**Do NOT use GNU sed** (`/var/jb/usr/bin/sed`) to strip shebangs — it corrupts files due to
`\n`/`\r\n` line-ending differences. Use procursus `python3` on the iOS side instead.

**Applies to**: Any shell script, Python script, Ruby script, Perl script, Tcl script — any
text file with a `#!` first line that is exec'd via `execve`.

**Exception**: Scripts invoked by `bash script.sh` or `python3 script.py` (not exec'd directly)
are not affected since bash/python handle them without calling `execve` on the script file.

---

## Environment Variables for `run_bash.sh` Sessions

`launchdchrootexec` sets a minimal environment. Always export the following at the start of
any chroot session or script:

```bash
# Minimal working environment for the macOS chroot:
export PATH=/opt/local/bin:/opt/local/sbin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export HOME=/Users/root
export USER=root
export TMPDIR=/tmp
export SHELL=/bin/bash

# If you need network access (DNS goes through the SOCKS5 proxy):
export ALL_PROXY=socks5h://127.0.0.1:1082
export HTTPS_PROXY=socks5h://127.0.0.1:1082
export HTTP_PROXY=socks5h://127.0.0.1:1082
# Note: use socks5h:// (NOT socks5://) so DNS is resolved through the proxy too

# DYLD_INSERT_LIBRARIES is set automatically by launchdchrootexec; do not override it.
# If a subprocess strips it (e.g. via exec env -i), re-inject:
export DYLD_INSERT_LIBRARIES=/usr/local/lib/libmachook.dylib
```

**`launchdchrootexec` pre-sets**: `HOME=/Users/root`, `USER=root`, `TMPDIR=/tmp`,
`DYLD_INSERT_LIBRARIES=/usr/local/lib/libmachook.dylib`.

**PATH is inherited from the iOS shell** — always set it explicitly inside scripts.

---

## AGX-Native Environment Variables (libmachook + WindowServer plist)

These are read by `libmachook` via `getenv()` at image-load time. The
production switches live in `layout/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist`
under `<key>EnvironmentVariables</key>`. After editing the plist, **unload + load** the
job — `launchctl kickstart -k` does NOT refresh env.

```bash
sudo launchctl unload /var/jb/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist
sudo launchctl load   /var/jb/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist
```

### Currently shipped in WindowServer plist (2026-06-19)

| Var | Value | Purpose | Status |
|---|---|---|---|
| `CA_VSYNC_OFF` | `1` | CoreAnimation skips vblank wait — required, IOMFBServer's CADisplay handoff doesn't reach chroot | always-on |
| `MACWS_AGX_NATIVE` | `1` | Master gate for AGX-native code path (vs. fallback MTLSim path). Disables the legacy `getenv("MACWS_KEEP_FORCE_ACCEL")` shim that returns the simulator MTLDevice | always-on for goal |
| `MACWS_AGX_REGISTER_CLASSES` | `1` | Walks `_dyld_image_count()` per loaded image, runs `objc_readClassPair` on every `__objc_classlist` entry. Required because Metal eager-dlopens AGXMetal13_3 before `_dyld_objc_notify_register`, so `objc_getClass("AGXBuffer") = 0x0` without this | always-on for goal |
| `MACWS_PIN_FALLBACK` | `1` | Installs the `setupCompiler`-time AGXBuffer 4-arg initFull swizzle that returns an IOSurface-backed buffer when AGXIOC sel=0x9 ResCreate fails. RE-confirmed only fires from `setupCompiler:` path; the cascade-blocker `Mempool::grow` calls `IOGPUResourceCreate` directly (no ObjC hook can intercept) | always-on for goal |

### Disabled / removed (RE- or runtime-disproved)

| Var | Why removed | Evidence |
|---|---|---|
| `MACWS_AGX_BORROW_CONN` | Tried to XPC-borrow `io_connect_t` from `macwsallocd` so chroot WS could reuse iOS-side-opened AGX UC | RE-disproved: `xpc_dictionary_set_mach_send(reply, "connect", conn)` followed by `xpc_connection_send_message` triggers `EXC_GUARD ILLEGAL_MOVE` on the io_connect_t mach port — IOKit guards io_connect_t at the kernel-port level, structurally cannot cross processes |
| `MACWS_AGX_FORCE_TYPE` | Override the `type` argument to `IOServiceOpen` (0/1/2 etc.) to coerce a privileged AGX user-client variant | runtime-disproved: type=0 and type=2 hang `IOServiceOpen` (no return), type=1 returns a degraded UC that still rejects sel=0x9 with `0xe00002c2`. Masking `0x100001`→`1` is the only value that doesn't hang and is kept in `IOServiceOpen_new` as the default |
| `MACWS_AGXIOC_FUZZ` | Perturb args+0x08..+0x60 by 1-byte/4-byte/8-byte deltas on sel=0x9 failure | runtime-disproved as a fix: ALL 10 perturbations across +0x08..+0x60 fail SAME code `0xe00002c2`. Kernel rejection isn't args-shape — and isn't `IOGPU+0x108` either (RE-measured 5.13 GB, see `misc/agx_iogpu_probe.c`). Real reject site still being RE'd |
| `MACWS_SUSPEND_AT_EXEC` | `SIGSTOP` self right after libmachook ctor to allow lldb attach before any ObjC class load | debug-only, never ship to plist — leaves WS frozen across respring |

### Diagnostic / opt-in (set in shell, not plist)

| Var | Effect | When to use |
|---|---|---|
| `MACWS_AGX_CRASH_DIAG` | Installs a SIGSEGV handler that dumps x0–x29, sp, faulting PC, the 64 bytes around PC, and 64-byte memory at x19 + at `*(x19+0x28)`. **Critical** for AGX-native crashes where the C++ frame is mid-vector-op and lldb can't unwind | every AGX-native debug session — sole reason the Mempool::grow root cause was findable |
| `MACWS_IOSURF_TRACE` | Logs every `IOSurfaceCreate` call + size + IOSurfaceID | when chasing cross-process IOSurface bridge issues |
| `MACWS_ABORT_TRACE` | Installs a hook that prints stack frames on `abort()` / `__assert_rtn` before the program dies | tracing where assert hits came from |
| `MACWS_HID_BYPASS` | Skip the bulk hook of 15 IOHIDEventSystem* APIs (kept narrow because bulk-hooking caused silent PAC-dispatch crashes) | leave OFF in production; the bulk hook produced a runtime-confirmed PAC-dispatch crash |
| `MACWS_AGC_VERIFY_BYPASS` | Skip `verifyLoweredIR` in AGXCompilerCore | out-of-process MTLCompilerService runs the compile, so this is inert in the chroot |
| `MACWS_AGC_FASTMATH_HOOK` | Renamer patch for `agx.air.fract.v3f16.fast` | superseded by `MTLCompilerBypassOSCheck` tweak (also out-of-process) |
| `MACWS_AGX_RENAMER_PATCH` | Alternative renamer patch entry-point | superseded — see above |
| `MACWS_AGX_OBJC_AUTDA_PATCH` | Patch libobjc `autda` → `xpacd` to survive pre-PAC-signed ObjC ivars (on-device lld arm64e fixup ABI) | runtime-confirmed needed only on certain re-signing flows; keep OFF unless diagnosing `autda` traps |
| `MACWS_AGX_SKIP_BIND_UPDATE` | NOP `MTLBindings::update_for_render_pass` BL inside AGX render-pass init (was a band-aid for setupDeferred crashes) | now implicit when `MACWS_AGX_NATIVE=1`; opt-out via `MACWS_AGX_KEEP_BIND_UPDATE=1` if testing without the skip |
| `MACWS_AGX_TEX_BYPASS_GATE` | Bypass the `validateBufferTextureWithSize:` magic-footer check (`0x99b7d4010ce3ead3 / 0x92482f97c0394fd0`) | superseded by always-on patch in `objc_hooks.c`; A/B knob |
| `MACWS_KEEP_VALIDATE_ALWAYS` | Restore the always-validate path | opposite of above — only when intentionally A/B'ing |
| `MACWS_KEEP_ASSERT_BYPASS` | Keep the blanket `__assert_rtn → log+return` patch even after fixes land | diagnostic scaffold only; never treat it as a fix, and honor it only for an explicitly requested A/B |
| `MACWS_KEEP_RENDER_UPDATE_CBZ` | Keep render_update CBZ-bypass | LAZY — same as above |
| `MACWS_GOT_SKIP_AUTH` | Skip authenticated-GOT slot patching during chained-fixup walker | diagnostic only — used while bootstrapping the chained-fixups walker; should be OFF in prod |
| `MACWS_GOT_RAW_AUTH` | Write raw (unsigned) pointer into auth-GOT (no `ptrauth_sign_unauthenticated`) | diagnostic only |

### Outside libmachook

| File / key | Value | Purpose |
|---|---|---|
| `layout/Library/LaunchDaemons/com.macwsguide.alloc.plist` `KeepAlive` | `False` | Prevents a runtime-confirmed rapid respawn loop when the handler crashes |
| `layout/Library/LaunchDaemons/com.macwsguide.alloc.plist` `ThrottleInterval` | `60` | Lower bound on respawn cadence even if launchd-side flag flips |
| `layout/Library/LaunchDaemons/com.macwsguide.alloc.plist` `RunAtLoad` | `True` | macwsallocd should be up before WS so the XPC service answer for `borrow-agx-conn` / `alloc-iosurf` is already listening |

### How to verify a var is active in the running WS

```bash
# Find WS PID (chroot binary, NOT iOS WindowServer if any):
PID=$(pgrep -f WindowServer | xargs -I{} sh -c 'ps -p {} -o command= | grep -q chroot && echo {}')

# Dump its env (kernel-stored; sudo required for foreign-user proc):
sudo ps -E -p "$PID" | tr ' ' '\n' | grep MACWS_
```

If a var is missing, the plist edit did not take effect (likely `launchctl
unload + load` was skipped, or the file inside the deb is being shadowed).

---

## Skills: Common Operations

### Skill: Sign and Trustcache a Single Binary

```bash
# On iOS shell (run_bash NOT needed — this is iOS-side ldid):
ENT=/var/jb/usr/macOS/bin/entitlements.plist
BIN=/var/mnt/rootfs/path/to/binary
sudo ldid -S"$ENT" -M "$BIN"
for arch in arm64 arm64e x86_64; do
    h=$(ldid -arch "$arch" -h "$BIN" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$h" ] && sudo /var/jb/usr/bin/jbctl trustcache add "$h" && echo "Trusted [$arch]: $h"
done
```

### Skill: Sign All Mach-O Files in a Directory Tree

Use `misc/sign_installed.sh` (deployed to `/var/jb/usr/macOS/bin/sign_installed.sh`).
This is the standard tool for signing after any `port install`, `brew install`, or `pip install`.

```bash
# Sign everything MacPorts installed (most common case after port install):
sudo bash /var/jb/usr/macOS/bin/sign_installed.sh macports

# Sign everything Homebrew installed:
sudo bash /var/jb/usr/macOS/bin/sign_installed.sh homebrew

# Sign both (default):
sudo bash /var/jb/usr/macOS/bin/sign_installed.sh

# Sign an arbitrary directory (e.g. after extracting a tarball):
sudo bash /var/jb/usr/macOS/bin/sign_installed.sh /var/mnt/rootfs/usr/local/myapp

# After pip install — sign new .so files in Python site-packages:
sudo bash /var/jb/usr/macOS/bin/sign_installed.sh \
  /var/mnt/rootfs/opt/local/Library/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages
```

The script is idempotent and safe to re-run at any time. It skips non-Mach-O files silently.

### Skill: Run a Multi-Line Script in the Chroot (Non-Interactive)

Place the script in the rootfs so it is accessible inside the chroot:
```bash
# Write script to rootfs (accessible inside chroot as /tmp/myscript.sh)
cat > /var/mnt/rootfs/tmp/myscript.sh << 'EOF'
export PATH=/opt/local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export ALL_PROXY=socks5h://127.0.0.1:1082
# ... script body ...
EOF

# Run it (no shebang needed — bash -s reads from stdin or bash <path> executes directly):
sudo bash /var/jb/usr/macOS/bin/run_bash.sh /tmp/myscript.sh
```

Or pipe inline via stdin (script stays on iOS filesystem):
```bash
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -s << 'EOF'
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
echo "hello from chroot"
EOF
```

### Skill: Strip Shebangs from a Directory of Scripts (iOS Side)

```bash
python3 << 'EOF'
import os, sys

target_dir = "/var/mnt/rootfs/opt/homebrew/Library/Homebrew/shims"
for root, dirs, files in os.walk(target_dir):
    for fname in files:
        fpath = os.path.join(root, fname)
        try:
            with open(fpath, 'r+', encoding='utf-8', errors='ignore') as f:
                content = f.read()
                if content.startswith('#!'):
                    newline_pos = content.find('\n')
                    if newline_pos != -1:
                        f.seek(0)
                        f.write(content[newline_pos+1:])
                        f.truncate()
                        print(f"Stripped shebang: {fpath}")
        except (IsADirectoryError, PermissionError):
            pass
EOF
```

### Skill: Check If a CDHash Is in the Trustcache

```bash
cdhash=$(ldid -arch arm64 -h /var/mnt/rootfs/path/to/binary 2>/dev/null | grep CDHash= | cut -c8-)
echo "CDHash: $cdhash"
jbctl trustcache info | grep -i "$cdhash" && echo "IN trustcache" || echo "NOT in trustcache"
```

**Note**: Use `jbctl trustcache info` to dump the trustcache contents. `jbctl trustcache list`
always returns empty output and does not work for checking trustcache membership.

### Skill: Debug Why a Binary Is Being Killed

```bash
# Watch AMFI/kernel logs while running the binary in another session:
sudo dmesg | grep -E 'AMFI|deny|kill|sigkill' | tail -20
# Or:
sudo oslog | grep "AMFI\|violation\|kill"
```

### Skill: Install MacPorts Package (After Base is Set Up)

```bash
# Inside chroot, with proxy set:
export ALL_PROXY=socks5h://127.0.0.1:1082
export PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin
port install <package>

# After install, sign all new Mach-O files (run from iOS shell, NOT inside chroot):
# (use the bulk-sign skill above, targeting /var/mnt/rootfs/opt/local)
```

---

## Package Manager Notes

- **MacPorts** (`/opt/local`): Works. Has prebuilt binaries for macOS 13 arm64. `port` binary
  is a Mach-O (no shebang issue). After each `port install`, re-sign all new Mach-O files.
  See `docs/macports-notes.md` for full details.

- **Homebrew** (`/opt/homebrew`): Does NOT work for package installation on macOS 13 arm64 —
  no bottles available, source builds require Xcode CLT (AMFI-killed). `brew --version` can
  be made to work but `brew install` fails. See `docs/homebrew-notes.md` for full details.

---

## Python 3.13 (MacPorts)

Installed as `port install python313`. Confirmed working as of 2026-03-15 (version 3.13.12).

### Required: sign all Mach-O files after install

Run `/tmp/sign_python313.sh` (iOS side) or the bulk-sign skill from CLAUDE.md targeting
`/opt/local/Library/Frameworks/Python.framework/Versions/3.13` and `/opt/local/lib`.

### pip setup

```bash
# Install pip (bundled with Python 3.13):
python3.13 -m ensurepip --upgrade

# pip needs PySocks to use a SOCKS5 proxy. Bootstrap it via curl:
curl -sL --proxy socks5h://127.0.0.1:1082 --cacert /etc/ssl/cert.pem \
  "https://files.pythonhosted.org/packages/a2/4b/52123768624ae28d84c97515dd96c9958888e8c2d8f122074e31e2be878c/PySocks-1.7.1-py27-none-any.whl" \
  -o /tmp/PySocks-1.7.1-py3-none-any.whl
python3.13 -m pip install --no-deps /tmp/PySocks-1.7.1-py3-none-any.whl
```

### Required environment variables for Python sessions

```bash
export SSL_CERT_FILE=/etc/ssl/cert.pem           # macOS cert bundle (Security fw unreachable in chroot)
export ALL_PROXY=socks5h://127.0.0.1:1082        # DNS-aware SOCKS5 proxy
export HTTPS_PROXY=socks5h://127.0.0.1:1082
# Include the Python framework bin for pip3/pip3.13 commands:
export PATH=/opt/local/Library/Frameworks/Python.framework/Versions/3.13/bin:$PATH
```

### After every `pip install` — sign new .so files (from iOS shell)

```bash
ENT=/var/jb/usr/macOS/bin/entitlements.plist
SITE=/var/mnt/rootfs/opt/local/Library/Frameworks/Python.framework/Versions/3.13/lib/python3.13/site-packages
find "$SITE" -type f \( -name "*.so" -o -name "*.dylib" \) | while read f; do
    sudo ldid -S"$ENT" -M "$f" 2>/dev/null
    h=$(ldid -arch arm64 -h "$f" 2>/dev/null | grep CDHash= | cut -c8-)
    [ -n "$h" ] && sudo /var/jb/usr/bin/jbctl trustcache add "$h" && echo "signed: $(basename $f)"
done
```

### Confirmed working modules

`sys`, `os`, `json`, `re`, `math`, `hashlib`, `sqlite3`, `ssl`, `zlib`, `lzma`, `bz2`, `csv`,
`ctypes`, `decimal`, `readline`, `multiprocessing`, `concurrent.futures`,
`requests` (pip), `charset_normalizer` (pip), `certifi` (pip), `urllib3` (pip)

---

## Debugging Techniques

### Skill: Reproduce the Basic Sanity Test

```bash
# Quick smoke test — must exit 0 and print "hi":
ssh -p <SSH_PORT> mobile@<DEVICE> \
  'sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c "echo hi" 2>&1; echo "exit: $?"'
# "chdir: No such file or directory" on stderr is harmless (falls back to /).
# Any non-zero exit or SIGTRAP means libmachook is broken.
```

### Skill: Read Crash Reports (iOS CrashReporter)

macOS binaries running inside the chroot are reported by iOS CrashReporter:

```bash
# List recent bash crashes:
ls -t /private/var/mobile/Library/Logs/CrashReporter/bash*.ips | head -5

# Key fields to extract from a .ips crash report (JSON format):
#   exception.type        — EXC_BREAKPOINT = PAC trap or __builtin_trap
#   exception.signal      — SIGTRAP = Trace/BPT trap
#   threads[].threadState.esr.description — "(Breakpoint) pointer authentication trap DA"
#   threads[].frames[].symbol — call stack symbols
#   usedImages[].path     — loaded images at crash time

# Quick parse (procursus python3, NOT inside chroot):
python3 -c "
import json, sys
data = json.loads(open(sys.argv[1]).readlines()[1])   # skip first line (metadata)
print('Exception:', data['exception'])
print('ESR:', data['threads'][0]['threadState'].get('esr', {}))
for f in data['threads'][0]['frames'][:10]:
    print(' ', f.get('symbol','?'), '+', f.get('symbolLocation',0))
" /private/var/mobile/Library/Logs/CrashReporter/bash-XXXX.ips
```

**Common crash signatures:**

| Signal | ESR description | Cause |
|--------|----------------|-------|
| SIGTRAP / EXC_BREAKPOINT | pointer authentication trap DA | `autda` on unsigned or wrongly-signed pointer — ObjC class data PAC mismatch |
| SIGTRAP / EXC_BREAKPOINT | (none / BRK) | `abort()`, ObjC uncaught exception, `__builtin_trap()` |
| SIGKILL (exit 137) | — | AMFI denial or sandbox violation |

### Skill: Inspect Mach-O Fixup Format

```python
# Check LC_DYLD_INFO_ONLY vs LC_DYLD_CHAINED_FIXUPS for each slice:
python3 - /path/to/binary <<'EOF'
import struct, sys
data = open(sys.argv[1],'rb').read()
LC_DYLD_INFO_ONLY=0x80000022; LC_DYLD_CHAINED_FIXUPS=0x80000034
nfat = struct.unpack_from('>I', data, 4)[0]
for i in range(nfat):
    ct,cs,off,sz,_ = struct.unpack_from('>IIIII', data, 8+i*20)
    name = {(0x0100000c,0):'arm64',(0x0100000c,2):'arm64e'}.get((ct,cs&0xFF),'?')
    hdr = struct.unpack_from('<IIIIIIII', data, off)
    cmd_off = off + 32
    for _ in range(hdr[4]):
        cmd,sz2 = struct.unpack_from('<II', data, cmd_off)
        if cmd==LC_DYLD_CHAINED_FIXUPS: print(f'{name}: LC_DYLD_CHAINED_FIXUPS')
        if cmd==LC_DYLD_INFO_ONLY:      print(f'{name}: LC_DYLD_INFO_ONLY')
        cmd_off += sz2
EOF
```

**arm64e + LC_DYLD_INFO_ONLY**: lld on-device stores ObjC `class_t->data` as a
PAC-pre-signed value (iOS keys).  macOS libobjc's `autda` fails → PAC trap.

**arm64e + LC_DYLD_CHAINED_FIXUPS** (what `-Wl,-fixup_chains` gives): lld stores
`class_t->data` as a plain non-auth rebase.  macOS libobjc's `autda` still fails
on an unsigned pointer.  **Workaround**: guard ObjC class definitions with
`#ifndef __arm64e__` so no `class_t` entries exist in the arm64e slice.

### Skill: Attach lldb to a Stuck macOS Process

macOS binaries that hang (waiting for XPC / WindowServer / Metal init) can be
debugged by attaching iOS lldb from the iOS shell:

```bash
# 1. Launch the process in background from a chroot session:
sudo bash /var/jb/usr/macOS/bin/run_bash.sh -c \
  "export PATH=/usr/local/bin:/usr/bin:/bin; /path/to/MacOS/Binary &" &

# 2. Find its PID (it is a macOS arm64e process):
sleep 2 && pgrep -n Binary

# 3. Attach lldb (iOS-side lldb at /var/jb/usr/bin/lldb):
sudo /var/jb/usr/bin/lldb -p <PID>

# 4. Inside lldb — get all thread backtraces to find what's blocking:
(lldb) thread backtrace all
(lldb) process interrupt     # pause if running
(lldb) bt all                # same as thread backtrace all
```

Key lldb commands for diagnosing hangs:
- `thread list` — list all threads and their current state
- `thread backtrace all` — full stack for every thread
- `frame info` — details about current frame
- `p (char*)dlerror()` — check last dyld/dl error
- `image list` — all loaded images (check if Metal/libmachook loaded)
- `process detach` — detach without killing

### Known arm64e libmachook Issues (on-device lld)

| Problem | Root cause | Fix |
|---------|-----------|-----|
| PAC trap in `readClass` on `MTLFakeDevice` | on-device lld emits plain non-auth chained fixup for `class_t->data`; macOS libobjc does `autda` → trap | Guard `MTLFakeDevice` with `#ifndef __arm64e__` in `Metal_hooks.x` |
| Arm64-only dylib rejected | macOS arm64e dyld rejects DYLD_INSERT_LIBRARIES dylib without arm64e slice | Keep `ARCHS = arm64 arm64e` in `libmachook/Makefile` |
| arm64e chroot process SIGKILL'd at load (`KILL - CODESIGNING / Invalid Page`); backtrace `dyld4::...forEachInsertedDylib → mapFileReadOnly → hasMachOMagic()`; arm64 unaffected | **`cp -f` over the rootfs libmachook reuses the SAME inode** → the chroot kernel's cached code-signature blob for that vnode goes stale, so the new file's pages validate against the OLD hashes → AMFI Invalid Page. File/sig/trustcache all look correct (page hashes are self-consistent); the kernel just isn't using this blob. arm64 escapes only because WindowServer stays mapped from one clean load. Spans reboots (every rebuild re-`cp -f`'s in place). | **`rm -f` the dest before `cp`** so the refreshed dylib gets a NEW inode (no stale cached blob). Done in `layout/usr/macOS/bin/postinst.sh`. Verified: rm+cp → `run_bash.sh -c "echo hi"` → exit 0. |

**Note:** `jbctl trustcache info` REQUIRES root on this build (despite the "no sudo" note earlier in this file) — without sudo it errors out, and grepping its (empty) output yields false "not trusted" results.

---

## On-Device Debug Workflows

### Skill: USB SSH via `iproxy` (port 22222 → device 22)

Wi-Fi SSH (`ssh -p <SSH_PORT> mobile@<DEVICE>`) is convenient but can fail
when the device WiFi flaps under heavy iOS load (high load average kills WiFi
keepalive). USB SSH stays up regardless of CPU pressure.

```bash
# On macOS host, start iproxy in a background-friendly mode:
brew install libimobiledevice   # provides `iproxy`
iproxy 22222 22 &               # forwards localhost:22222 → device:22

# Then SSH stays on localhost — survives WiFi outages:
ssh -p 22222 root@127.0.0.1
```

Add to `~/.ssh/config` for convenience:
```
Host ipad-usb
    HostName 127.0.0.1
    Port 22222
    User root
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

Then: `ssh ipad-usb 'uptime'`.

**Practical rule**: any session involving lldb (long-lived TCP), `oslog -f`
streaming, or repeated builds — use USB SSH. The cost of a dropped TCP is
re-attaching lldb from scratch, which loses all breakpoint state.

### Skill: lldb on iOS via tmux (`misc/ios_lldb_tmux.sh`)

The iOS Procursus lldb has **no python scripting**, **no expression evaluator**,
and `lldb-server` crashes on attach. Only `debugserver` works on the iOS side
for remote lldb-from-mac, but that path needs every breakpoint round-trip to
ping the dyld shared cache on the host (slow). For interactive RE we use
**iOS-local lldb driven via tmux** — symbol lookups stay on-device and we
never restart the lldb session.

```bash
# Attach (creates a persistent tmux session named "ioslldb"):
bash misc/ios_lldb_tmux.sh attach 127.0.0.1 22222 WindowServer

# Send one lldb command and read the reply:
bash misc/ios_lldb_tmux.sh cmd 'register read x0 x21'
bash misc/ios_lldb_tmux.sh cmd 'br set -n IOConnectCallMethod -c "$x1 == 0xa"'
bash misc/ios_lldb_tmux.sh cmd 'continue'

# Multi-line (use only -o per BP — iOS lldb has no script):
bash misc/ios_lldb_tmux.sh cmd-multi <<'EOF'
breakpoint command add 1
register read x0 x1 x2 x3
continue
DONE
EOF

# Dump latest pane output:
bash misc/ios_lldb_tmux.sh capture 400

# Detach + kill session cleanly:
bash misc/ios_lldb_tmux.sh stop
```

**Quirks discovered (runtime-verified):**

| Quirk | Workaround |
|---|---|
| `br set -n foo -c "selector == 10"` fails — iOS lldb cannot parse arg names | Use registers: `br set -n IOConnectCallMethod -c '$x1 == 0xa'` |
| `memory read --size 8 --count 8` chooses default format incorrectly under some lldb builds → garbled output | Always pass `--format x` explicitly |
| `script` / `script-language` / `expression` all unavailable | Pre-compute the value on host, paste literal. For loops, use `br command add -o cmd1 -o cmd2 -o continue` (single `-o` per line) |
| tmux under sudo errors `LC_CTYPE: cannot set locale` and `/tmp/tmux-501` permission denied | Wrap: `sudo env LC_CTYPE=UTF-8 TMUX_TMPDIR=/var/tmp tmux ...` |
| Attaching to a process that already has TXs state can hang the attach | `process detach` from any prior lldb first; if no lldb, `kill -CONT $PID` then re-attach |
| `image list` returns the chroot image set — NOT iOS dyld_cache. Symbols there map to chroot paths | Cross-binary lookups must run separately against `~/Downloads/agx-re/` slid binaries with capstone |

**`MACWS_SUSPEND_AT_EXEC=1` pattern** for early-startup RE: makes libmachook
`raise(SIGSTOP)` in its `__attribute__((constructor))` so the process is
frozen BEFORE any framework init. Then attach iOS lldb, set breakpoints in
AGXMetal13_3 / SkyLight / IOSurface, then `process signal SIGCONT`. Without
this, the crash happens during one of the deep-load initializers and lldb
catches it after the fact.

```bash
# In WS plist EnvironmentVariables (TEMPORARY — never ship):
<key>MACWS_SUSPEND_AT_EXEC</key>
<string>1</string>
```

### Skill: `FAST=1 bash build_on_ios.sh` — what it skips, what trips it

`build_on_ios.sh` defaults to a full clean build (~20s on iPad13,6). Add
`FAST=1` (or `--fast`) and it skips `make clean` + skips `make package` +
just `cp`s the rebuilt `libmachook.{arm64,arm64e}.dylib` to
`/var/mnt/rootfs/usr/local/lib/` and runs the libmachook-only postinst step.
Cuts to ~3s.

**The guardrail (auto-fallback to full)**:
```
FAST=1 → check mtime of MTLCompilerBypassOSCheck / launchdchrootexec /
        autosignd / MTLSimDriverHost / launchservicesd / mountdevfs /
        Makefile / control / layout against /var/jb/usr/lib/TweakInject/
        MTLCompilerBypassOSCheck.dylib — if ANY source newer → FAST=0
```

This is critical: `FAST` only ships libmachook. Any edit to:
- `MTLCompilerBypassOSCheck/Tweak.x` — out-of-process Substrate tweak hooks won't refresh
- `launchdchrootexec/*` — chroot loader won't refresh
- `autosignd/*` — re-sign daemon won't refresh
- `MTLSimDriverHost/*` — XPC host won't refresh
- `layout/usr/macOS/LaunchDaemons/*.plist` — env vars and ProgramArgs won't refresh
- `layout/Library/LaunchDaemons/com.macwsguide.*.plist` — iOS-side daemons won't refresh
- `layout/usr/macOS/bin/*.sh` — helper scripts won't refresh

... requires the full path (deb build + `dpkg -i`). The guardrail forces it.

**Common FAST trip case**:
```
==> FAST guardrail tripped: source files newer than last dpkg-installed tweak:
      layout/usr/macOS/LaunchDaemons/com.apple.WindowServer.plist
==> Forcing full build (FAST only ships libmachook; deb-installed bits would stay stale)
```
This is correct behavior — you edited the plist; `cp libmachook` would have
hidden the change.

**Pitfall — `git stash` + `git checkout -- file` interaction**: stash only
saves PRE-stash uncommitted changes. If you `git stash`, then
`git checkout commit -- some_file`, that creates a NEW modification not in
the stash. `git stash pop` will NOT restore the original. Always
`git status` after stash operations.

**Pitfall — running `build_on_ios.sh` without `THEOS`**: SSH does not
inherit `THEOS` from the device's interactive shell. Always:
```bash
ssh -p 22222 root@127.0.0.1 \
  'THEOS=/var/jb/var/mobile/theos bash /var/jb/var/mobile/MacWSBootingGuide/misc/build_on_ios.sh'
```
without that prefix you'll see `Theos not found` and the build silently
falls back to system make rules.

**Pitfall — `cp -f` over rootfs libmachook reuses the same inode** — already
fixed in `layout/usr/macOS/bin/postinst.sh` (it `rm -f`s the dest first),
but if you write a side-channel that bypasses postinst (e.g. `scp` directly
to `/var/mnt/rootfs/usr/local/lib/libmachook.dylib`) you'll hit the AMFI
Invalid Page bug. See the Known arm64e Issues table above.

### Skill: AGXIOC selector argument FUZZ (`MACWS_AGXIOC_FUZZ=1`)

When kernel rejects an `IOConnectCallMethod` with a structurally-correct
error code (`0xe00002c2 = kIOReturnNotPermitted`), the question is whether
the rejection is **input-shape** (some args field is invalid for this
selector) or **structural** (the UC doesn't have permission regardless of
input).

The fuzz path in `mac_hooks.m` perturbs args at +0x08, +0x10, +0x18, ...,
+0x60 by 1-byte / 4-byte / 8-byte deltas around the failing call and re-runs
each variant. The expected outcomes:

| Result | Interpretation |
|---|---|
| One or two perturbations succeed (return 0) | Input-shape — narrow on which field controls the gate |
| **ALL** perturbations fail same error code | Structural — kernel doesn't look at args. (Previously attributed to `device->0x108==0` per-UC field — DISPROVEN; see `misc/agx_iogpu_probe.c` measurement of `+0x108 = 5.13 GB`.) Real reject site still being RE'd |
| Some perturbations cause `IOServiceClose`-on-error | The kernel is doing input validation, fuzz has triggered a different validation path |

**RE-confirmed for sel=0x9 ResCreate**: all 10 perturbations fail `0xe00002c2`.
Conclusion: structural for this historical path; the three blocked approaches
and their evidence are summarized earlier in this file.

### Skill: One-shot hex dump for large opaque struct inputs

When an external method takes a 1032-byte `inputStruct` (sel=0x7/0x8 args)
and we don't know the layout, dump it ONCE per (PID, selector) tuple:

```c
/* In IOConnectCallMethod_new, after the failing call: */
static dispatch_once_t dumped[16];
if (selector < 16) {
    dispatch_once(&dumped[selector], ^{
        /* Head: first 256 bytes, hex+ascii */
        fprintf(stderr, "#### sel=%llu inputStructCnt=%zu head256:\n", selector, inputStructCnt);
        hex_dump_chunk((const char *)inputStruct, MIN(inputStructCnt, 256));
        /* Tail: scan past 256 for non-zero u64s */
        const uint64_t *u = (const uint64_t *)inputStruct;
        size_t cnt = inputStructCnt / 8;
        for (size_t i = 32; i < cnt; ++i) {
            if (u[i]) fprintf(stderr, "    +%#zx: %#llx\n", i * 8, u[i]);
        }
    });
}
```

The "head + non-zero scan" pattern beats raw `xxd` because the typical iOS
AGX inputStruct is `512 zero, qos@0x400, 504 more zero` — the head shows
the live fields, the scan catches the late qos slot without spamming.

### Skill: Cross-binary RE with capstone for arm64e kexts

`otool -tV /System/Library/Extensions/AGXKextG13.kext/...` fails on arm64e
kext bundles — the disassembler doesn't decode PAC-flavored auth-call
opcodes. Use macholib + capstone instead:

```python
import macholib.MachO, capstone
m = macholib.MachO.MachO('/path/to/AGXKextG13')
hdr = m.headers[0]
slide = next(s.vmaddr for c, _, s in hdr.commands if hasattr(s, 'segname') and s.segname == b'__TEXT')
text  = next(c for c, _, _ in hdr.commands if hasattr(c, 'segname') and c.segname == b'__TEXT')
# capstone CS_MODE_ARM disasm
cs = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
cs.detail = True
data = open('/path/to/AGXKextG13', 'rb').read()
# disasm function at unslid 0xfffffe0009f03b4c → file offset
off = 0xfffffe0009f03b4c - slide + text.fileoff
for ins in cs.disasm(data[off:off+0x400], 0xfffffe0009f03b4c):
    print(f"{ins.address:#x}  {ins.mnemonic:6s}  {ins.op_str}")
```

This is the only way to read `IOGPUDevice::new_resource +0xff` (the source
of the `0xe00002c2` rejection) — BN MCP works too but the macholib+capstone
loop fits inline into our usual evidence-discipline workflow.

### Skill: Read AGX-native crash report stack with mid-vector PCs

AGX-native crashes typically die mid-vector-op (PC inside a 256-byte
`memmove` / `__bzero` / `memcpy` slot) and lldb cannot unwind across the
fault. The `MACWS_AGX_CRASH_DIAG` SIGSEGV handler dumps register + memory
snapshot — combine with the `.ips` crash report's framepointers:

```bash
# 1. Find the latest WindowServer crash:
ls -t /private/var/mobile/Library/Logs/CrashReporter/WindowServer-*.ips | head -1

# 2. Parse exception PC + key frames:
python3 - "$1" <<'EOF'
import json, sys
data = json.loads(open(sys.argv[1]).readlines()[1])
print('exception:', data['exception'])
print('threadState x19=', hex(data['threads'][0]['threadState']['x'][19]['value']))
print('threadState x0=',  hex(data['threads'][0]['threadState']['x'][0]['value']))
print('pc=',              hex(data['threads'][0]['threadState']['pc']['value']))
print('faulting frames:')
for f in data['threads'][0]['frames'][:8]:
    print(f"  {f.get('imageIndex','?'):3} +{f.get('imageOffset','?'):#x}  {f.get('symbol','?')}")
print('images:')
for f in data['threads'][0]['frames'][:8]:
    idx = f.get('imageIndex')
    if idx is None: continue
    img = data['usedImages'][idx]
    print(f"  {idx:3}  base={img['base']:#x}  {img['name']}")
EOF

# 3. With the chosen image's `base` and frame offset, look up the macOS
#    AGXMetal13_3 (in ~/Downloads/agx-re/) symbol at base+offset using BN
#    or capstone+addr2line.
```

The `MACWS_AGX_CRASH_DIAG` log line and the `.ips` exception are
**redundant by design** — if one is missing or corrupted (oslog buffer
overflow, crashreporter race), the other is usually intact.
