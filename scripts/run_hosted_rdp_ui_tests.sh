#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/JTSTerminal.xcodeproj"
SCHEME="JTSTerminalRDP2"
CONFIGURATION="Debug"
DESTINATION="${JTS_HOSTED_RDP_UI_DESTINATION:-platform=macOS}"
DEFAULT_ARTIFACT_ROOT="${TMPDIR:-/tmp}/jts-terminal-hosted-rdp-ui-tests"
ARTIFACT_ROOT="${JTS_HOSTED_RDP_UI_ARTIFACT_ROOT:-$DEFAULT_ARTIFACT_ROOT}"

TEST_IDENTIFIERS=(
  "JTSTerminalRDP2UITests/JTSTerminalUITests/testHostedRDPConnectedViewingShowsAIControlsWithoutLeaseCountdown"
  "JTSTerminalRDP2UITests/JTSTerminalUITests/testHostedRDPConnectedControlShowsAIControlsWithoutLeaseCountdown"
  "JTSTerminalRDP2UITests/JTSTerminalUITests/testHostedRDPRemoteInputFocusReturnsToLocalUIWhenWindowDeactivates"
  "JTSTerminalRDP2UITests/JTSTerminalUITests/testHostedRDPStoppingShowsAIControlsWithoutLeaseCountdown"
  "JTSTerminalRDP2UITests/JTSTerminalUITests/testHostedRDPNarrowLayoutKeepsCriticalControlsAndMovesSecondaryActions"
  "JTSTerminalRDP2UITests/JTSTerminalUITests/testHostedRDPPersistentGrantApprovalAndRevocation"
  "JTSTerminalRDP2UITests/JTSTerminalUITests/testSavingNewServerClosesPropertiesSheet"
)

usage() {
  cat <<'EOF'
Usage: scripts/run_hosted_rdp_ui_tests.sh [options]

Options:
  --artifact-root PATH     Store this run beneath PATH
  --destination VALUE     Override the xcodebuild destination
  --list-tests            Print the hosted RDP UI test identifiers and exit
  --help, -h              Show this help

Every execution creates a private per-run DerivedData directory. The runner
never uses Xcode's project-wide default DerivedData, because the 1.2 and 2.0
targets intentionally share their final app and Swift module product names.
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" ]]; then
    printf 'Missing value for %s.\n' "$option" >&2
    usage >&2
    exit 2
  fi
}

while (( $# > 0 )); do
  case "$1" in
    --artifact-root)
      require_value "$1" "${2:-}"
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --destination)
      require_value "$1" "${2:-}"
      DESTINATION="$2"
      shift 2
      ;;
    --list-tests)
      printf '%s\n' "${TEST_IDENTIFIERS[@]}"
      exit 0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"
umask 077

/bin/mkdir -p "$ARTIFACT_ROOT"
timestamp="$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
run_directory="$(
  /usr/bin/mktemp -d "$ARTIFACT_ROOT/${timestamp}-XXXXXXXX"
)"
/bin/chmod 700 "$run_directory"

DERIVED_DATA_PATH="$run_directory/DerivedData"
RESULT_BUNDLE_PATH="$run_directory/HostedRDPUI.xcresult"
LOG_PATH="$run_directory/xcodebuild.log"
ONLY_TESTING_ARGUMENTS=()
for test_identifier in "${TEST_IDENTIFIERS[@]}"; do
  ONLY_TESTING_ARGUMENTS+=("-only-testing:${test_identifier}")
done

printf 'Hosted RDP UI artifacts: %s\n' "$run_directory"
printf 'Private DerivedData: %s\n' "$DERIVED_DATA_PATH"

set +e
/usr/bin/xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -enableCodeCoverage NO \
  -resultBundlePath "$RESULT_BUNDLE_PATH" \
  -parallel-testing-enabled NO \
  SDK_STAT_CACHE_ENABLE=NO \
  test \
  "${ONLY_TESTING_ARGUMENTS[@]}" 2>&1 | /usr/bin/tee "$LOG_PATH"
test_status="${PIPESTATUS[0]}"
set -e

if (( test_status != 0 )); then
  printf 'Hosted RDP UI tests failed with status %s. Evidence: %s\n' \
    "$test_status" "$run_directory" >&2
  exit "$test_status"
fi

printf 'Hosted RDP UI tests passed. Evidence: %s\n' "$run_directory"
