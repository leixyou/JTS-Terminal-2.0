# Pinned FreeRDP runtime

The Mac RDP helper uses a minimal static FreeRDP 3.31.1 build with OpenSSL 3.6.4.
It never discovers or launches a Homebrew `xfreerdp` process.

Generate the ignored runtime input before compiling:

```sh
scripts/build_freerdp.sh
```

The script verifies pinned source archive SHA-256 values, builds arm64 and
x86_64 slices, applies the checked-in explicit-empty-clipboard patch, and emits
`JTFreeRDP.xcframework`, license files, the cpufeatures NOTICE and a CycloneDX SBOM.
The enabled client channels include clipboard, display control, dynamic channels
and graphics. Server, audio and broad device redirection features are disabled.

`JTFreeRDP.xcframework` is intentionally not a Git source input. Rebuild whenever
pinned sources or patches change, then run the relevant dependency/runtime
checks before distribution. Keep licenses and third-party notices with binaries.
