#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_BUNDLE_PATH="${1:-${APP_BUNDLE_PATH:-}}"
if [[ -z "${APP_BUNDLE_PATH}" || ! -d "${APP_BUNDLE_PATH}" ]]; then
  print -u2 "Usage: APP_BUNDLE_PATH=/path/to/JTS\\ Terminal.app ${0}"
  exit 2
fi

SOURCE_XPC="${APP_BUNDLE_PATH}/Contents/XPCServices/JTFreeRDPService.xpc"
SOURCE_XPC_EXECUTABLE="${SOURCE_XPC}/Contents/MacOS/JTFreeRDPService"
if [[ ! -x "${SOURCE_XPC_EXECUTABLE}" ]]; then
  print -u2 "The supplied app does not contain an executable JTFreeRDPService.xpc."
  exit 2
fi
if ! rg -a -q 'crashForTestingWithReply:' "${SOURCE_XPC_EXECUTABLE}"; then
  print -u2 "The supplied app is not a Debug build with the isolated XPC crash test hook."
  exit 2
fi

TEMP_ROOT="$(mktemp -d /tmp/jts-rdp-xpc-crash.XXXXXX)"
trap 'rm -rf "${TEMP_ROOT}"' EXIT
TEST_APP="${TEMP_ROOT}/JTS Terminal XPC Crash Test.app"
/usr/bin/ditto "${APP_BUNDLE_PATH}" "${TEST_APP}"

HARNESS_NAME="JTFreeRDPXPCCrashHarness"
HARNESS="${TEST_APP}/Contents/MacOS/${HARNESS_NAME}"
xcrun clang \
  -DDEBUG=1 \
  -fobjc-arc \
  -fblocks \
  -Wall \
  -Wextra \
  -Werror \
  -framework Foundation \
  -framework IOSurface \
  -I "${ROOT}/RDPXPCShared" \
  "${ROOT}/scripts/tests/JTFreeRDPXPCCrashRecoveryTests.m" \
  -o "${HARNESS}"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${HARNESS_NAME}" \
  "${TEST_APP}/Contents/Info.plist"
/usr/bin/codesign --force --sign - "${HARNESS}" >/dev/null
/usr/bin/codesign --force --deep --sign - "${TEST_APP}" >/dev/null

"${HARNESS}"
