#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS=1000
MAX_DVC_LENGTH=1048576
OUTPUT_DIR=""

usage() {
  echo "Usage: robustness/run_rdp_robustness.sh [--runs N] [--max-dvc-length N] [--output DIR]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      RUNS="${2:-}"
      shift 2
      ;;
    --max-dvc-length)
      MAX_DVC_LENGTH="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! "$RUNS" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$MAX_DVC_LENGTH" =~ ^[1-9][0-9]*$ ]] ||
   (( MAX_DVC_LENGTH > 16777216 )); then
  echo "runs and max length must be positive integers; max DVC length is 16 MiB." >&2
  exit 2
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT_DIR/build/security/rdp-sanitizers/$(date -u +%Y%m%dT%H%M%SZ)"
elif [[ "$OUTPUT_DIR" != /* ]]; then
  OUTPUT_DIR="$ROOT_DIR/$OUTPUT_DIR"
fi

if [[ -n "${LLVM_PREFIX:-}" ]]; then
  LLVM_ROOT="$LLVM_PREFIX"
elif command -v brew >/dev/null 2>&1 && brew --prefix llvm >/dev/null 2>&1; then
  LLVM_ROOT="$(brew --prefix llvm)"
else
  echo "Homebrew LLVM is required because Apple clang does not ship the required input runtime." >&2
  echo "Install it with 'brew install llvm' or set LLVM_PREFIX to an LLVM installation." >&2
  exit 2
fi

CLANGXX="$LLVM_ROOT/bin/clang++"
if [[ ! -x "$CLANGXX" ]]; then
  echo "clang++ was not found under LLVM_PREFIX: $CLANGXX" >&2
  exit 2
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is required for the production DVC/reconnect target." >&2
  exit 2
fi

RESOURCE_DIR="$($CLANGXX -print-resource-dir)"
LLVM_INPUT_RUNTIME="$RESOURCE_DIR/lib/darwin/libclang_rt.fuzzer_osx.a"
if [[ ! -f "$LLVM_INPUT_RUNTIME" ]]; then
  echo "The Homebrew LLVM input runtime was not found: $LLVM_INPUT_RUNTIME" >&2
  exit 2
fi

BUILD_DIR="$OUTPUT_DIR/bin"
CORPUS_DIR="$OUTPUT_DIR/corpus"
ARTIFACT_DIR="$OUTPUT_DIR/artifacts"
LOG_PATH="$OUTPUT_DIR/run.log"
SUMMARY_PATH="$OUTPUT_DIR/summary.txt"
mkdir -p "$BUILD_DIR" "$CORPUS_DIR" "$ARTIFACT_DIR"
cp -R "$ROOT_DIR/robustness/corpus/dvc_reconnect" "$CORPUS_DIR/"
cp -R "$ROOT_DIR/robustness/corpus/framebuffer" "$CORPUS_DIR/"

STATUS=failed
write_summary() {
  {
    echo "status=$STATUS"
    echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "runs_per_target=$RUNS"
    echo "max_dvc_length=$MAX_DVC_LENGTH"
    echo "llvm_prefix=$LLVM_ROOT"
    echo "swift_compiler=$(swiftc --version | head -n 1)"
    echo "native_target=Homebrew LLVM input runtime plus ASan/UBSan over production framebuffer safety helpers"
    echo "swift_target=LLVM input driver plus Apple Swift ASan over production DVC codec and reconnect reducer"
    echo "swift_binary_chunk_selftest=Apple Swift ASan deterministic boundaries over production DVC codec, reassembler, and disconnect cleanup"
    echo "scope_limit=This script covers JTS framebuffer and DVC paths. Run scripts/run_rdp_parser_robustness.sh for the FreeRDP capability parser gate."
    echo "log=$LOG_PATH"
  } > "$SUMMARY_PATH"
}
trap write_summary EXIT

exec > >(tee "$LOG_PATH") 2>&1

echo "Building RDP sanitizer targets in $OUTPUT_DIR"
"$CLANGXX" --version | head -n 3
swiftc --version

"$CLANGXX" \
  -std=c++20 \
  -DJTS_FRAMEBUFFER_ONLY \
  -fsanitize=fuzzer,address,undefined \
  -fno-omit-frame-pointer \
  -g \
  -O1 \
  "$ROOT_DIR/robustness/RDPRobustnessDriver.cpp" \
  -o "$BUILD_DIR/jts-framebuffer-robustness"

"$CLANGXX" \
  -std=c++20 \
  -fsanitize=address,undefined \
  -fno-omit-frame-pointer \
  -g \
  -O1 \
  "$ROOT_DIR/robustness/RDPSafetySelfTest.cpp" \
  -o "$BUILD_DIR/jts-rdp-safety-selftest"

# Compile only the C++ input bridge without ASan here. Homebrew clang and
# Apple Swift currently ship different ASan ABI revisions; the production
# Swift sources themselves are instrumented and linked by swiftc below.
"$CLANGXX" \
  -std=c++20 \
  -DJTS_SWIFT_ONLY \
  -fsanitize=fuzzer-no-link \
  -g \
  -O1 \
  -c "$ROOT_DIR/robustness/RDPRobustnessDriver.cpp" \
  -o "$BUILD_DIR/swift-input-driver.o"

swiftc \
  -DENABLE_RDP_2 \
  -sanitize=address \
  -parse-as-library \
  -g \
  -O \
  "$ROOT_DIR/JTSTerminal/WindowsCompanion/DVCControlMessages.swift" \
  "$ROOT_DIR/JTSTerminal/WindowsCompanion/DVCProtocol.swift" \
  "$ROOT_DIR/JTSTerminal/WindowsCompanion/DVCBinaryReassembler.swift" \
  "$ROOT_DIR/JTSTerminal/RemoteDesktop/RDPReconnectSupervisor.swift" \
  "$ROOT_DIR/robustness/DVCReconnectRobustnessBridge.swift" \
  "$BUILD_DIR/swift-input-driver.o" \
  -Xlinker "$LLVM_INPUT_RUNTIME" \
  -Xlinker -lc++ \
  -o "$BUILD_DIR/jts-dvc-reconnect-robustness"

swiftc \
  -DENABLE_RDP_2 \
  -sanitize=address \
  -parse-as-library \
  -g \
  -O \
  "$ROOT_DIR/JTSTerminal/WindowsCompanion/DVCControlMessages.swift" \
  "$ROOT_DIR/JTSTerminal/WindowsCompanion/DVCProtocol.swift" \
  "$ROOT_DIR/JTSTerminal/WindowsCompanion/DVCBinaryReassembler.swift" \
  "$ROOT_DIR/JTSTerminal/WindowsCompanion/BinaryTransferClient.swift" \
  "$ROOT_DIR/robustness/DVCBinaryChunkRobustnessSelfTest.swift" \
  -o "$BUILD_DIR/jts-dvc-binary-chunk-robustness-selftest"

# Homebrew LLVM input runtime keeps its RSS monitor thread alive through process exit,
# which LeakSanitizer reports as a runtime-owned 56-byte leak on macOS. Disable
# leak-only reporting while retaining fail-fast address and bounds checks.
export ASAN_OPTIONS="abort_on_error=1:detect_leaks=0:strict_string_checks=1"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"

"$BUILD_DIR/jts-rdp-safety-selftest"
"$BUILD_DIR/jts-dvc-binary-chunk-robustness-selftest"
"$BUILD_DIR/jts-framebuffer-robustness" \
  -seed=1337 \
  -runs="$RUNS" \
  -max_len=256 \
  -artifact_prefix="$ARTIFACT_DIR/framebuffer-" \
  "$CORPUS_DIR/framebuffer"
"$BUILD_DIR/jts-dvc-reconnect-robustness" \
  -seed=1337 \
  -runs="$RUNS" \
  -max_len="$MAX_DVC_LENGTH" \
  -artifact_prefix="$ARTIFACT_DIR/dvc-reconnect-" \
  "$CORPUS_DIR/dvc_reconnect"

STATUS=passed
echo "RDP sanitizer targets passed. Evidence: $OUTPUT_DIR"
