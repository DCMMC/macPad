# Apple Account sign-in

This opt-in adapter restores the Apple Account sign-in path in a macOS
15.6.1 / 24G90 guest on the qualified iPadOS 16.2 / Darwin 22.2.0 workspace.
It uses the guest's original account, authentication, and keychain services.

The adapter provides private Mach and notification namespaces, independent
APNs delegate registration for guest akd, the real Aqua user-session context,
and the native device-keybag selector required by the guest Security and
CryptoTokenKit clients. The original services still perform authentication,
certificate validation, key generation, and account persistence.

The Apple Account pane loads the original account service-owner bundle from
its permitted executable directory. A read-only sysctl capability crosses the
native-to-guest exec through an anonymous pipe. The original AuthKit web flow
gets a bounded 90-second load interval and a normal AppKit redraw when its
verification page becomes available.

`iCloudHelper` is an internal dependency of the original account-save callback.
Its adapter exposes the genuine helper through a private Mach endpoint and
forwards the original peer to the original request handler and client validation.
The public feature covered here is the primary Apple Account sign-in flow.

## Build

Use Xcode with both macOS and iPhoneOS SDKs. Supply a copy of the qualified
guest rootfs, including its original system executables, authentication
plugins, and the existing Apple Account ExtensionKit runtime:

```sh
python3 AppleIDSignIn/build.py \
  --rootfs "$MACWS_ROOTFS" \
  --output /tmp/macpad-appleid-payload
python3 -m unittest discover -s AppleIDSignIn -p 'test_*.py' -v
```

The output directory must be new. The build compiles every adapter and the
native carrier, validates ad-hoc signatures and entitlements, checks immutable
Apple input hashes, and records output hashes in `manifest.json`. Load-command
edits preserve the original UUID and every code/data section. Generated Apple
executables and plugin bundles stay in the local payload; they are not source
repository assets.

`inputs.json` identifies the original service images. `service-entitlements.json`
contains the exact qualified guest service policies. `jobs.json` contains the
private launchd registrations and the existing native15 chroot launcher contract.
`plugins.json` pins the original authentication plugins used by the account flow.

## Install

Use the already prepared Sequoia workspace with its native15 Settings carrier,
per-pane hook composition, original trustd peers, and exec-admission services.
The installer verifies that contract before replacing any file. This adapter
is deliberately installed separately from the default Ventura package.

Close the workspace, transfer the generated payload to a root-owned directory
on the device, and run from the native device shell:

```sh
/var/jb/usr/bin/python3 /path/to/macpad-appleid-payload/native/install.py \
  /path/to/macpad-appleid-payload
```

The installer refuses active account jobs, writes replacements using new
inodes, preserves backups, updates only the Apple Account carrier's identity
records, admits the verified code hashes through the project's trust backend,
and verifies the complete installed dependency closure. A failed transaction
restores the previous files. It does not start a sign-in or remove account data.

Opening Apple Account starts the eleven private guest backends and unlocks the
guest login keychain using a random password protected by the device's real
data-protection keychain. Credentials and capability tokens never appear in
command arguments or plaintext state files. The workspace cleanup hook stops
only these owned services and preserves the existing account/keychain stores.

Service status is available from the native device shell:

```sh
/var/jb/usr/bin/python3 -I /var/jb/usr/macOS/bin/macws_private_account15.py status
```

## Validation

During the October 21 device session, the original signing path returned a
signature with error zero, account-save returned
`SignInPreflightSave DidSave=1 Error=0`, and the user completed the primary
Apple Account flow. The visible account page showed Personal Information,
Sign-In & Security, and the device list. The existing signed-in session was
retained while preparing this source contribution.

The packaged sources are compiled and signed again by `build.py`; build
verification and the local regression tests are separate from that historical
device acceptance. The installer remains opt-in and does not replace the
iPadOS system, kernel, activation state, or boot chain.

## Evidence behind the adapters

* APSConnection's designated initializer passes `namedDelegatePort` into the
  connection key (`0x189e8426c` in the analyzed image). Distinct native/guest
  delegate names prevent their real connections from replacing each other.
* CoreCDPInternal's `_eligiblePrimaryAccountForFlow:error:` creates
  `CDPStateError -5102` on the no-primary-account branch at `0x1b1b08bd8`.
  The adapter preserves that real pre-login result.
* AuthKitUI's `_createWaitTimer` at `0x19a6c3240` supplies 30 seconds. Runtime
  observed the original timer fail before the web resources completed at
  about 38 seconds. The adapter changes only that default interval to 90 seconds.
* AOSKit's connection routine at `0x1ae29aa54` uses bundled XPC. The original
  helper's `main` at `0x1000027d8` registers its handler with `xpc_main`;
  client validation at `0x100005adc` remains original. The private adapter
  changes transport registration, not the request or authentication protocol.
* The native/guest AppleKeyStore and CryptoTokenKit implementations were
  compared before mapping the guest user-session bag selector `-3` to the
  native device bag `0`. Input buffers, encryption classes, and real errors
  pass through unchanged; no keybag is created or reset by that mapping.

The critical control-flow findings were checked with independent disassembly
engines and runtime witnesses. Exact-image and version guards remain in the
sources; these addresses are evidence for the pinned profile, not generic
cross-version offsets.
