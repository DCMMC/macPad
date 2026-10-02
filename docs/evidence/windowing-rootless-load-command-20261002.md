# MacWSWindowing rootless load-command regression (2026-10-02)

## User-visible regression

On the iPad13,6 / iPadOS 16.3.1 target, resizing a MacWSHost Scene exposed
only the small stock iPadOS candidate set. Finder document windows landed on
sizes such as `891x807`, `1004x807`, `1177x922`, and `1389x970`. Finder still
published the correct independent AppKit policies:

```text
window-auto-scene identity=19497:g:1023 title=Recents ... logical=851.0x449.0 minimum=317.0x284.0 fixed=NOxNO
window-auto-scene identity=19497:g:1029 title=About Finder ... logical=301.0x326.0 minimum=301.0x326.0 fixed=YESxYES
```

This ruled out loss of the fixed/resizable distinction in Host metadata.
MacWSHost instead reported the exact bridge failure:

```text
scene-size-restrictions unavailable ... route=springboard-exact-scene-policy
scene-native-size unavailable ... reason=windowing-bridge-not-loaded
```

LLDB's image list for the running SpringBoard contained `systemhook.dylib`
and `libellekit.dylib`, but no `MacWSWindowing.dylib`.

## Runtime-confirmed cause

A temporary arm64e loader probe ran inside SpringBoard's real dyld namespace.
Its complete load result was:

```text
pid=20738 target=/var/jb/Library/MobileSubstrate/DynamicLibraries/MacWSWindowing.dylib image=0x0 error=dlopen(..., 0x0006): Library not loaded: /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
  Referenced from: <68A6F37E-C1B6-3B78-BDBD-917DE79018D6> .../usr/lib/TweakInject/MacWSWindowing.dylib
  Reason: tried: '/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate' (errno=2), ...
```

Runtime-confirmed: the installed image had been built with the rootful Theos
load command. Its signature, arm64e CDHash, trust-cache entry, and
authenticated `__cfstring` fixups were valid, but those properties could not
make the absent absolute dependency resolvable on Dopamine rootless.

The correct `THEOS_PACKAGE_SCHEME=rootless` build carries:

```text
@rpath/MacWSWindowing.dylib
@rpath/CydiaSubstrate.framework/CydiaSubstrate
```

It was installed by copying to a new path and atomically renaming it, then
SpringBoard was restarted. LLDB subsequently showed the image mapped, and the
runtime logged:

```text
chamois-windowing-state known=YES active=YES source=frame-calculator
dense-grid-result ... proposed=1194.0x807.0 ... result=1194.0x807.0 candidates=127x82 stock=8x4 policy=sceneID:com.macwsguide.host-...
```

The temporary loader probe and ElleKit logging marker were removed after the
observation.

## Permanent guard

`misc/deploy_macwswindowing.sh` and `misc/macws_artifact_contract.py` now
inspect the finished image's `LC_LOAD_DYLIB` entries. They fail closed on any
`/Library/...` dependency or on the absence of the rootless
`@rpath/CydiaSubstrate.framework/CydiaSubstrate` dependency. Unit tests cover
both rejection and acceptance. This protects continuous Host-only sizing and
fixed AppKit window sizing together; it does not make fixed windows resizable
or replace the native floating-Dock policy with a maximum-height constraint.
