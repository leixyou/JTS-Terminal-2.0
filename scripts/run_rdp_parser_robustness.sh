#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS=1000
OUTPUT_DIR=""
FREERDP_VERSION="$(sed -n 's/^FREERDP_VERSION="\([^"]*\)"$/\1/p' "$ROOT_DIR/scripts/build_freerdp.sh")"
if [[ ! "$FREERDP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Pinned FreeRDP version is missing or malformed." >&2
  exit 2
fi
FREERDP_BUILD_ROOT="${JTS_FREERDP_BUILD_ROOT:-$ROOT_DIR/build/freerdp-$FREERDP_VERSION}"
FREERDP_SOURCE_DIR="$FREERDP_BUILD_ROOT/freerdp-source-arm64"
OPENSSL_ROOT_DIR="$FREERDP_BUILD_ROOT/openssl-install-arm64"

usage() {
  echo "Usage: scripts/run_rdp_parser_robustness.sh [--runs N] [--output DIR] [--freerdp-source DIR] [--openssl-root DIR]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs)
      RUNS="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --freerdp-source)
      FREERDP_SOURCE_DIR="${2:-}"
      shift 2
      ;;
    --openssl-root)
      OPENSSL_ROOT_DIR="${2:-}"
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

if [[ ! "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "runs must be a positive integer." >&2
  exit 2
fi

if [[ ! -d "$FREERDP_SOURCE_DIR/libfreerdp/core" ]]; then
  echo "FreeRDP source tree was not found: $FREERDP_SOURCE_DIR" >&2
  exit 2
fi
if [[ ! -d "$OPENSSL_ROOT_DIR/include" ]] ||
   [[ ! -f "$OPENSSL_ROOT_DIR/lib/libssl.a" ]] ||
   [[ ! -f "$OPENSSL_ROOT_DIR/lib/libcrypto.a" ]]; then
  echo "Pinned OpenSSL build was not found under: $OPENSSL_ROOT_DIR" >&2
  exit 2
fi

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$ROOT_DIR/build/security/rdp-parser-robustness/$(date -u +%Y%m%dT%H%M%SZ)"
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

CLANG="$LLVM_ROOT/bin/clang"
CLANGXX="$LLVM_ROOT/bin/clang++"
if [[ ! -x "$CLANG" ]] || [[ ! -x "$CLANGXX" ]]; then
  echo "clang/clang++ were not found under LLVM_PREFIX: $LLVM_ROOT" >&2
  exit 2
fi
if ! command -v cmake >/dev/null 2>&1; then
  echo "cmake is required." >&2
  exit 2
fi
if ! command -v ninja >/dev/null 2>&1; then
  echo "ninja is required." >&2
  exit 2
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "xcrun is required to locate the macOS SDK." >&2
  exit 2
fi

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
ZLIB_LIBRARY="$SDKROOT/usr/lib/libz.tbd"
if [[ ! -f "$ZLIB_LIBRARY" ]]; then
  echo "macOS SDK zlib stub was not found: $ZLIB_LIBRARY" >&2
  exit 2
fi

BUILD_DIR="$OUTPUT_DIR/build"
CORPUS_DIR="$OUTPUT_DIR/corpus"
ARTIFACT_DIR="$OUTPUT_DIR/artifacts"
LOG_PATH="$OUTPUT_DIR/run.log"
SUMMARY_PATH="$OUTPUT_DIR/summary.txt"
mkdir -p "$BUILD_DIR" "$CORPUS_DIR" "$ARTIFACT_DIR"
cp -R "$ROOT_DIR/robustness/corpus/freerdp_capabilities" "$CORPUS_DIR/"

STATUS=failed
write_summary() {
  {
    echo "status=$STATUS"
    echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "runs=$RUNS"
    echo "llvm_prefix=$LLVM_ROOT"
    echo "freerdp_source=$FREERDP_SOURCE_DIR"
    echo "openssl_root=$OPENSSL_ROOT_DIR"
    echo "target=jts-freerdp-capability-robustness"
    echo "coverage=FreeRDP capability-set readers in client and server directions plus Demand Active and Confirm Active PDU parsers"
    echo "corpus=$CORPUS_DIR/freerdp_capabilities"
    echo "log=$LOG_PATH"
  } > "$SUMMARY_PATH"
}
trap write_summary EXIT

exec 3>&1 4>&2
if [[ "${JTS_RDP_ROBUSTNESS_TEE:-0}" == "1" ]]; then
  exec > >(tee "$LOG_PATH") 2>&1
else
  exec > "$LOG_PATH" 2>&1
fi

echo "Building FreeRDP parser robustness target in $OUTPUT_DIR"
"$CLANG" --version | head -n 3
cmake --version | head -n 1

env CC="$CLANG" CXX="$CLANGXX" cmake \
  -S "$ROOT_DIR/robustness/freerdp-capability" \
  -B "$BUILD_DIR" \
  -G Ninja \
  -DCMAKE_OSX_SYSROOT="$SDKROOT" \
  -DCMAKE_C_FLAGS="-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1" \
  -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address,undefined" \
  -DBUILD_SHARED_LIBS=ON \
  -DWITH_AOM=OFF \
  -DWITH_CHANNELS=OFF \
  -DWITH_CLIENT_INTERFACE=OFF \
  -DWITH_CLIENT_MAC=OFF \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_CAIRO=OFF \
  -DWITH_FAAC=OFF \
  -DWITH_FAAD2=OFF \
  -DWITH_FDK_AAC=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_GFX_AV1=OFF \
  -DWITH_GFX_AZURE=OFF \
  -DWITH_GSM=OFF \
  -DWITH_JPEG=OFF \
  -DWITH_JSON_DISABLED=ON \
  -DWITH_KRB5=OFF \
  -DWITH_LAME=OFF \
  -DWITH_LODEPNG=OFF \
  -DWITH_OPENCL=OFF \
  -DWITH_OPENH264=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_PCSC=OFF \
  -DWITH_PKCS11=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_SERVER=OFF \
  -DWITH_SERVER_INTERFACE=OFF \
  -DWITH_SIMD=OFF \
  -DWITH_SOXR=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_THIRD_PARTY=OFF \
  -DWITH_URIPARSER=OFF \
  -DWITH_X11=OFF \
  -DWITH_YUV=OFF \
  -DOPENSSL_ROOT_DIR="$OPENSSL_ROOT_DIR" \
  -DOPENSSL_INCLUDE_DIR="$OPENSSL_ROOT_DIR/include" \
  -DOPENSSL_SSL_LIBRARY="$OPENSSL_ROOT_DIR/lib/libssl.a" \
  -DOPENSSL_CRYPTO_LIBRARY="$OPENSSL_ROOT_DIR/lib/libcrypto.a" \
  -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DZLIB_INCLUDE_DIR="$SDKROOT/usr/include" \
  -DZLIB_LIBRARY="$ZLIB_LIBRARY" \
  -DJTS_FREERDP_SOURCE_DIR="$FREERDP_SOURCE_DIR"

cmake --build "$BUILD_DIR" --target jts-freerdp-capability-robustness --parallel

export ASAN_OPTIONS="abort_on_error=1:detect_leaks=0:strict_string_checks=1"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"

"$BUILD_DIR/bin/jts-freerdp-capability-robustness" \
  -seed=1337 \
  -runs="$RUNS" \
  -max_len=65536 \
  -artifact_prefix="$ARTIFACT_DIR/capability-" \
  "$CORPUS_DIR/freerdp_capabilities"

STATUS=passed
echo "FreeRDP parser robustness target passed. Evidence: $OUTPUT_DIR"

if [[ "${JTS_RDP_ROBUSTNESS_TEE:-0}" != "1" ]]; then
  echo "FreeRDP parser robustness target passed. Evidence: $OUTPUT_DIR" >&3
fi
exec 3>&- 4>&-
