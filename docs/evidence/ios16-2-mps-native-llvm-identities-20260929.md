# iPadOS 16.2 native-LLVM MPS output identities — 2026-09-29

The package install on an iPad14,4 running iPadOS 16.2 stopped at the existing
fail-closed MPSCore output-identity check. It did not publish an unverified
translation. The source library matched the already pinned Ventura 13.4
identity exactly:

```text
ff2cca382dc21e3cdb4f5b567d6770917a32f388d36e64dffae595ea1601322b  .../MPSCore.framework/.../default.metallib
```

The device's installed Apple `libLLVM.dylib` produced these stable artifacts:

```text
342738608c912eab663879868288299e38147ea64d45b74f57bc0dd12761b2de  mpsimage/default-desktop-effects-macabi.metallib
8744686cc7981601f52f658578b9cd94cf9127c86530ee03a1e68883d2e3bb0c  mpscore/default-compute-macabi.metallib
fa6c9b109e9ab2a7356654bd16ba66715d4ac5a04eea75dec220418a01f90736  mpsndarray/default-compute-macabi.metallib
```

Runtime-confirmed on the device with the production verifier:

```text
verified profile=ventura13-ios19-macabi translated=1825 manifest=.../mpsimage-default.route.plist
verified profile=ventura13-ios19-macabi translated=4119 manifest=.../mpscore-default.route.plist
verified profile=ventura13-ios19-macabi translated=148 manifest=.../mpsndarray-default.route.plist
```

The same Ventura sources translated on the existing iPad14,5/iPadOS 16.0
deployment retain the earlier pinned MPSCore and MPSNDArray identities
`bc05c6df...` and `ff2d5117...`. The wrapper deliberately loads the installed
`/usr/lib/libLLVM.dylib`; therefore the exact output identity is tied to that
native Apple LLVM build. Production still requires both an explicitly pinned
SHA-256 and a complete source/output manifest. No target check, function, or
verification step is bypassed.
