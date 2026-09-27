#!/bin/bash
set -euo pipefail

# Xcode runs this for Debug, Release and archives before signing the bundle.
# A packaged timestamp remains accurate when the app is copied or reopened.
BUILD_INFO_OUTPUT="${SCRIPT_OUTPUT_FILE_0:?Xcode build-info output is required}"
mkdir -p "$(dirname "$BUILD_INFO_OUTPUT")"
/usr/bin/plutil -create xml1 "$BUILD_INFO_OUTPUT"
/usr/bin/plutil -insert BuildDateUTC -string "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$BUILD_INFO_OUTPUT"
/usr/bin/plutil -insert Configuration -string "${CONFIGURATION:?Xcode configuration is required}" "$BUILD_INFO_OUTPUT"
