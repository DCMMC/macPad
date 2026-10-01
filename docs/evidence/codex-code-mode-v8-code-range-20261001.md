# Codex Code Mode V8 CodeRange crash — 2026-10-01

## Scope

Device: iPadOS 16.3 at `192.168.1.2:2222`.

Binary: `/opt/local/bin/codex-code-mode-host`, arm64, UUID
`4D33D3D9-A8E6-3023-9E9B-53FA38F8CE89`, V8 `150.4.0`.

This note records the evidence for the target-scoped launch environment in
`libmachook/exec_hooks.c`. It is not a blanket assertion/abort bypass: the
helper retains V8's normal allocation and W^X transitions and uses MacWS's
existing page-granular JIT compatibility path.

## Crash witness

The same stack is present in the September 23/24 reports and in repeated
October 1 reports, including:

`/var/mobile/Library/Logs/CrashReporter/codex-code-mode-host-2026-10-01-195540.ips`

The crashing thread's report excerpt is:

```text
v8::base::OS::Abort
v8::internal::V8::FatalProcessOutOfMemory
v8::internal::IsolateGroup::EnsureCodeRange
v8::internal::Heap::SetUp
v8::internal::Isolate::Init
v8::Isolate::New
codex_code_mode_runtime::runtime::spawn_runtime
```

The exception is `EXC_BREAKPOINT (SIGTRAP)`, reached through V8's
`FatalOOM` path. The report's VM summary attributes about 33.3 GiB to memory
tag 255. This is a virtual-address reservation witness, not a measurement of
33.3 GiB resident physical memory.

## Binary evidence

RE-confirmed in the exact UUID above:

- `v8::internal::IsolateGroup::EnsureCodeRange` at `0x101ce3554` calls
  `CodeRange::InitReservation`; its false branch references the literal
  `Failed to reserve virtual memory for CodeRange` and calls
  `FatalProcessOutOfMemory`.
- `v8::internal::CodeRange::InitReservation` at `0x101e3557c` constructs a
  reservation of at least 64 MiB, tries the preferred 4-GiB window, and
  returns false if reservation or subsequent permission setup fails.
- `v8::base::OS::Allocate` at `0x101fb187c` calls `mmap`; V8 permission modes
  that require executable memory add Darwin `MAP_JIT` (`0x800`).

## Deterministic protocol reproduction

The host transport is a four-byte little-endian JSON byte length followed by
the JSON payload. A minimal run sends `connection/hello`, `session/open`, and
then `session/execute` with source `1+1`. Stdin must remain open until the
asynchronous execute response arrives.

Four fresh-process trials per condition produced:

| Launch environment | Completed | SIGTRAP | Response bytes |
|---|---:|---:|---:|
| default | 0/4 | 4/4 | 69 each |
| both JIT compatibility variables set to `1` | 4/4 | 0/4 | 602 each |

The two variables were:

```text
MACWS_JIT_MPROTECT_COMPAT=1
MACWS_JIT_FAULT_WRITE_COMPAT=1
```

The successful response contained both `execution/started` and the initial
`Result` for `1+1`; one captured execution completed in approximately 4.77 ms.
This proves forward progress through isolate creation and JavaScript execution,
not merely process uptime.

## Production invariant

Every exec-family path interposed by `exec_hooks.c` recognizes only the exact
basename `codex-code-mode-host`, removes caller-supplied duplicates, and gives
that child both validated W^X adapter variables. `execv`/`execvp` temporarily
adjust the process environment under the existing exec mutex and restore the
parent environment if exec returns. Other executables do not inherit this new
target-specific policy.

Regression source contract:

```bash
python3 misc/test_codex_code_mode_runtime.py
```

## Post-fix device acceptance

After building both arm64 and arm64e slices on the device, installing the
thin dylibs, re-signing them, and updating the trustcache, the same protocol
probe explicitly unset both compatibility variables in its parent shell.
The target-specific exec adapter supplied the child contract automatically:

| Trial | Exit | Response bytes | Executed | Host duration |
|---:|---:|---:|---|---:|
| 1 | 0 | 602 | yes | 4,413,250 ns |
| 2 | 0 | 602 | yes | 4,246,833 ns |
| 3 | 0 | 602 | yes | 4,325,917 ns |
| 4 | 0 | 602 | yes | 4,341,833 ns |

Every response included `execute/initialResponse` with status `ok`. A
separate failed-exec/return-path check printed `parent-env-clean`, confirming
that the two target variables did not remain in the launching shell. No new
`codex-code-mode-host-*.ips` appeared after the deployment and five executed
protocol probes.

The final source, rebuilt after adding the non-target restoration guard,
completed one more fresh probe with exit `0`, all five response frames,
`execute_status=ok`, and host duration `4,404,167 ns`; the post-build crash
report query remained empty.
