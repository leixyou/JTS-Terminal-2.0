# JTS Terminal 2.0 RDP Robustness Harness

This directory contains local, bounded robustness targets for production code in the isolated 2.0 worktree.

Run the JTS framebuffer/DVC targets with:

```bash
robustness/run_rdp_robustness.sh --runs 1000
```

Run the FreeRDP capability parser target with:

```bash
scripts/run_rdp_parser_robustness.sh --runs 1000
```

The scripts auto-detect Homebrew LLVM (or accept `LLVM_PREFIX`), build into timestamped `build/security/` evidence directories, copy the checked-in seeds before mutation, and record `summary.txt`, `run.log`, binaries, working corpora, and any crash artifacts. Apple clang does not include the required LLVM input runtime, so the scripts fail with an explicit installation hint when Homebrew LLVM is unavailable.

Targets:

- `jts-framebuffer-robustness`: Homebrew LLVM input engine + ASan + UBSan over the same header-only paint-state, source bitmap, checked arithmetic, framebuffer/stride/IOSurface allocation, dirty-rectangle, and final-byte copy-region helpers used by `JTFreeRDPEngine.m`.
- `jts-dvc-reconnect-robustness`: arbitrary input is passed through the production Swift DVC whole/incremental codecs, control/binary/heartbeat validation, replay guard, encode/decode round trip, and reconnect state reducer. Production Swift code is compiled with AddressSanitizer. The tiny Homebrew C++ input shim is deliberately not ASan-instrumented because Homebrew LLVM and Apple Swift currently ship different ASan ABI revisions.
- `jts-freerdp-capability-robustness`: arbitrary and hex-encoded seeds exercise FreeRDP's production capability-set readers in both client and server directions, plus Demand Active and Confirm Active PDU parsers with fresh contexts.
- `jts-rdp-safety-selftest`: deterministic ASan/UBSan assertions for boundary and last-byte cases before the mutation runs begin.

The corpus has control, binary, incremental, disconnect/reconnect, edge-pixel, clipped-rectangle, and extreme-integer seeds. Protocol rejection is an expected outcome; sanitizer findings, traps, assertion failures, and nonzero exits fail the script.

Scope is intentionally precise: these harnesses exercise JTS's DVC and framebuffer boundary code plus the FreeRDP capability parser. Windows/XPC crash containment and distribution-signed candidate recovery still require their separate release gates.
