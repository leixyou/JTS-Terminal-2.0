#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_ROOT="${RDP_XPC_TEST_OUTPUT_ROOT:-${ROOT}/build/security/rdp-xpc-hardening}"
mkdir -p "${OUTPUT_ROOT}"

SANITIZER="${RDP_XPC_SANITIZER:-none}"
SANITIZER_FLAGS=()
case "${SANITIZER}" in
  none)
    ;;
  address-undefined)
    SANITIZER_FLAGS=(-fsanitize=address,undefined -fno-omit-frame-pointer)
    ;;
  thread)
    SANITIZER_FLAGS=(-fsanitize=thread -fno-omit-frame-pointer)
    ;;
  *)
    print -u2 "Unsupported RDP_XPC_SANITIZER: ${SANITIZER} (expected none, address-undefined, or thread)"
    exit 2
    ;;
esac

BINARY="${OUTPUT_ROOT}/rdp-xpc-hardening-tests-${SANITIZER}"
xcrun clang \
  -fobjc-arc \
  -fblocks \
  -Wall \
  -Wextra \
  -Werror \
  -framework Foundation \
  -I "${ROOT}/JTFreeRDPService" \
  -I "${ROOT}/Vendor/FreeRDP/JTFreeRDP.xcframework/macos-arm64_x86_64/Headers" \
  "${ROOT}/JTFreeRDPService/JTFreeRDPDeferredReleasePool.m" \
  "${ROOT}/JTFreeRDPService/JTFreeRDPTextClipboardBridge.m" \
  "${ROOT}/JTFreeRDPService/JTFreeRDPXPCValidation.m" \
  "${ROOT}/JTFreeRDPService/JTFreeRDPCommandQueue.m" \
  "${ROOT}/scripts/tests/JTFreeRDPXPCHardeningTests.m" \
  "${SANITIZER_FLAGS[@]}" \
  -o "${BINARY}"

ASAN_OPTIONS="halt_on_error=1:abort_on_error=1" \
UBSAN_OPTIONS="halt_on_error=1:abort_on_error=1" \
TSAN_OPTIONS="halt_on_error=1:abort_on_error=1" \
  "${BINARY}"
