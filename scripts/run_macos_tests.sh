#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${ROOT}/JTSTerminal.xcodeproj"
SCHEME="${JTS_MACOS_TEST_SCHEME:-JTSTerminalRDP2}"
CONFIGURATION="${JTS_MACOS_TEST_CONFIGURATION:-Debug}"
HOST_ARCH="$(uname -m)"
DEFAULT_TEST_ARCH="$HOST_ARCH"
if [[ "$HOST_ARCH" == "arm64" ]]; then
  DEFAULT_TEST_ARCH="x86_64"
fi
DESTINATION="${JTS_MACOS_TEST_DESTINATION:-platform=macOS,arch=$DEFAULT_TEST_ARCH}"
BUILD_TIMEOUT_SECONDS="${JTS_MACOS_BUILD_TIMEOUT_SECONDS:-300}"
DIRECT_TIMEOUT_SECONDS="${JTS_MACOS_DIRECT_TEST_TIMEOUT_SECONDS:-120}"
TESTMANAGER_TIMEOUT_SECONDS="${JTS_MACOS_TESTMANAGER_TIMEOUT_SECONDS:-120}"
TEST_TIMEOUT_SECONDS="${JTS_MACOS_TEST_TIMEOUT_SECONDS:-60}"
MAXIMUM_TEST_TIMEOUT_SECONDS="${JTS_MACOS_MAXIMUM_TEST_TIMEOUT_SECONDS:-120}"
DISABLE_CODE_SIGNING=0
RUN_TESTMANAGER=0
REQUIRE_TESTMANAGER=0
SKIP_TESTMANAGER=0
TEST_BUILD_STARTED=0
ONLY_TESTING_ARGUMENTS=()
ONLY_TESTING_COUNT=0
DERIVED_DATA_PATH=""
RESULT_BUNDLE_PATH=""
HOSTED_TEST_BUNDLE_PATH=""
EXTRA_XCODEBUILD_ARGUMENTS=()
EXTRA_XCODEBUILD_ARGUMENT_COUNT=0

ACTIVE_COMMAND_PID=""
ACTIVE_WATCHDOG_PID=""
ACTIVE_TEE_PID=""
ACTIVE_FIFO=""

usage() {
  cat <<'EOF'
Usage: scripts/run_macos_tests.sh [options] [-- xcodebuild arguments]

Options:
  --scheme NAME                Must be JTSTerminalRDP2
  --configuration NAME         Build configuration (default: Debug)
  --destination DESTINATION    xcodebuild destination, including architecture
  --derived-data PATH          DerivedData (default: DerivedData/Tests)
  --only-testing IDENTIFIER    Unit suite/method; one selected Xcode test run
  --result-bundle PATH         Supplemental TestManager xcresult path
  --wall-timeout SEC           Set every phase timeout to SEC
  --build-timeout SEC          Stop build-for-testing after SEC
  --direct-timeout SEC         Stop direct XCTest after SEC
  --testmanager-timeout SEC    Stop TestManager diagnostics after SEC
  --unsigned                   Diagnostic only: disable Xcode code signing
  --with-testmanager           Also run supplemental Xcode TestManager diagnostics
  --skip-testmanager           Skip supplemental diagnostics (the default)
  --require-testmanager        Enable supplemental diagnostics and require success
  --help                       Show this help

The default unit gate is one direct XCTest run against the bundle built by
Xcode. --only-testing JTSTerminalRDP2Tests/TestSuite[/testMethod] instead runs
one filtered xcodebuild test, covering both XCTest and Swift Testing without
appending an unfiltered direct run. Repeat the option to select more tests.
Build products are reused and excess development apps removed after testing.
Supplemental TestManager diagnostics are opt-in; they never run by default.
This development runner does not replace the full unit/UI release gate.

Normal project signing is preserved by default. --unsigned is diagnostic only;
the arm64 linker can still emit an ad-hoc signature, so it is not a reliable
workaround for the observed dyld/fcntl bundle-load stall. On Apple Silicon the
default is the stable x86_64/Rosetta test path; pass an arm64 destination when
diagnosing the native Xcode bundle-loader issue.
EOF
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    echo "Missing value for ${option}" >&2
    usage >&2
    exit 2
  fi
}

require_positive_integer() {
  local label="$1"
  local value="$2"
  case "${value}" in
    ""|0|*[!0-9]*)
      echo "${label} must be a positive integer: ${value}" >&2
      exit 2
      ;;
  esac
}

reject_routing_xcodebuild_argument() {
  local argument="$1"
  case "${argument}" in
    -scheme|-scheme=*|-project|-project=*|-workspace|-workspace=*|-target|-target=*|\
    -testPlan|-testPlan=*|-xctestrun|-xctestrun=*|-testProductsPath|-testProductsPath=*|\
    -configuration|-configuration=*|-destination|-destination=*|\
    -derivedDataPath|-derivedDataPath=*)
      echo "Extra xcodebuild arguments cannot override the fixed RDP2 test route: ${argument}" >&2
      exit 2
      ;;
    -only-testing*|-skip-testing*)
      echo "Use --only-testing JTSTerminalRDP2Tests/TestClass[/testMethod]; raw test filters cannot safely select direct XCTest." >&2
      exit 2
      ;;
  esac
}

add_test_selection() {
  local identifier="$1"
  if [[ ! "${identifier}" =~ ^JTSTerminalRDP2Tests/[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*(\(\))?)?$ ]]; then
    echo "Expected unit selection JTSTerminalRDP2Tests/TestClass[/testMethod]: ${identifier}" >&2
    exit 2
  fi
  # This target uses Swift Testing. Xcode can report success with zero tests
  # when a method selector omits its trailing parentheses.
  if [[ "${identifier}" == */*/* && "${identifier}" != *"()" ]]; then
    identifier="${identifier}()"
  fi
  ONLY_TESTING_ARGUMENTS+=("-only-testing:${identifier}")
  ONLY_TESTING_COUNT=$((ONLY_TESTING_COUNT + 1))
}

cleanup_active_processes() {
  if [[ -n "${ACTIVE_WATCHDOG_PID}" ]]; then
    terminate_process_tree TERM "${ACTIVE_WATCHDOG_PID}"
    wait "${ACTIVE_WATCHDOG_PID}" >/dev/null 2>&1 || true
    ACTIVE_WATCHDOG_PID=""
  fi
  if [[ -n "${ACTIVE_COMMAND_PID}" ]]; then
    pkill -TERM -P "${ACTIVE_COMMAND_PID}" >/dev/null 2>&1 || true
    kill -TERM "${ACTIVE_COMMAND_PID}" >/dev/null 2>&1 || true
    ACTIVE_COMMAND_PID=""
  fi
  if [[ -n "${ACTIVE_TEE_PID}" ]]; then
    kill "${ACTIVE_TEE_PID}" >/dev/null 2>&1 || true
    wait "${ACTIVE_TEE_PID}" >/dev/null 2>&1 || true
    ACTIVE_TEE_PID=""
  fi
  if [[ -n "${ACTIVE_FIFO}" ]]; then
    rm -f "${ACTIVE_FIFO}"
    ACTIVE_FIFO=""
  fi
}

handle_interrupt() {
  trap - EXIT
  cleanup_active_processes
  echo "Testing interrupted; run product retention after its processes have exited." >&2
  exit 130
}

finish_run() {
  local status=$?
  local interrupted_command="${ACTIVE_COMMAND_PID}"
  trap - EXIT
  cleanup_active_processes
  if (( TEST_BUILD_STARTED )) && [[ -z "${interrupted_command}" ]]; then
    terminate_detached_test_runners
    if ! /usr/bin/python3 "${ROOT}/scripts/retain_latest_debug_and_release.py" --repo-root "${ROOT}"; then
      echo "Build-product retention failed; inspect the reported active app before retrying." >&2
      (( status != 0 )) || status=1
    fi
  fi
  exit "${status}"
}

trap finish_run EXIT
trap handle_interrupt INT TERM

while (( $# > 0 )); do
  case "$1" in
    --scheme)
      require_value "$1" "${2:-}"
      SCHEME="$2"
      shift 2
      ;;
    --configuration)
      require_value "$1" "${2:-}"
      CONFIGURATION="$2"
      shift 2
      ;;
    --destination)
      require_value "$1" "${2:-}"
      DESTINATION="$2"
      shift 2
      ;;
    --derived-data)
      require_value "$1" "${2:-}"
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    --only-testing)
      require_value "$1" "${2:-}"
      add_test_selection "$2"
      shift 2
      ;;
    --result-bundle)
      require_value "$1" "${2:-}"
      RESULT_BUNDLE_PATH="$2"
      shift 2
      ;;
    --wall-timeout)
      require_value "$1" "${2:-}"
      BUILD_TIMEOUT_SECONDS="$2"
      DIRECT_TIMEOUT_SECONDS="$2"
      TESTMANAGER_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --build-timeout)
      require_value "$1" "${2:-}"
      BUILD_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --direct-timeout)
      require_value "$1" "${2:-}"
      DIRECT_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --testmanager-timeout)
      require_value "$1" "${2:-}"
      TESTMANAGER_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --unsigned)
      DISABLE_CODE_SIGNING=1
      shift
      ;;
    --skip-testmanager)
      RUN_TESTMANAGER=0
      SKIP_TESTMANAGER=1
      shift
      ;;
    --with-testmanager)
      RUN_TESTMANAGER=1
      shift
      ;;
    --require-testmanager)
      RUN_TESTMANAGER=1
      REQUIRE_TESTMANAGER=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_XCODEBUILD_ARGUMENTS+=("$@")
      EXTRA_XCODEBUILD_ARGUMENT_COUNT=$#
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_positive_integer "Build timeout" "${BUILD_TIMEOUT_SECONDS}"
require_positive_integer "Direct XCTest timeout" "${DIRECT_TIMEOUT_SECONDS}"
require_positive_integer "TestManager timeout" "${TESTMANAGER_TIMEOUT_SECONDS}"
require_positive_integer "Default test execution allowance" "${TEST_TIMEOUT_SECONDS}"
require_positive_integer "Maximum test execution allowance" "${MAXIMUM_TEST_TIMEOUT_SECONDS}"
if (( SKIP_TESTMANAGER && REQUIRE_TESTMANAGER )); then
  RUN_TESTMANAGER=0
fi
if (( ! RUN_TESTMANAGER && REQUIRE_TESTMANAGER )); then
  echo "--skip-testmanager and --require-testmanager cannot be used together." >&2
  exit 2
fi
if [[ "${SCHEME}" != "JTSTerminalRDP2" ]]; then
  echo "This 2.0 worktree only tests the JTSTerminalRDP2 scheme: ${SCHEME}" >&2
  exit 2
fi
if (( EXTRA_XCODEBUILD_ARGUMENT_COUNT > 0 )); then
  for argument in "${EXTRA_XCODEBUILD_ARGUMENTS[@]}"; do
    reject_routing_xcodebuild_argument "${argument}"
  done
fi

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
artifact_root="${JTS_MACOS_TEST_ARTIFACT_ROOT:-${TMPDIR:-/tmp}/jts-terminal-macos-tests}"
run_directory="${artifact_root}/${timestamp}-$$"
mkdir -p "${run_directory}"

if [[ -z "${DERIVED_DATA_PATH}" ]]; then
  DERIVED_DATA_PATH="${ROOT}/DerivedData/Tests"
fi
# TestManager mutates embedded signatures and injects frameworks into its host.
# Never permit that host to replace the daily Debug cache, including via aliases.
if ! /usr/bin/python3 - "${DERIVED_DATA_PATH}" "${ROOT}/DerivedData/Run" <<'PY'
from pathlib import Path
import sys

test_path, daily_path = (Path(value).resolve() for value in sys.argv[1:])
if test_path == daily_path or daily_path in test_path.parents or test_path in daily_path.parents:
    print("Test DerivedData must be separate from DerivedData/Run; use DerivedData/Tests.", file=sys.stderr)
    raise SystemExit(1)
PY
then
  exit 2
fi
if [[ -z "${RESULT_BUNDLE_PATH}" ]]; then
  RESULT_BUNDLE_PATH="${run_directory}/TestManagerResults.xcresult"
fi
mkdir -p "$(dirname "${RESULT_BUNDLE_PATH}")"

test_bundle_name="JTSTerminalRDP2Tests.xctest"
TEST_BUNDLE_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${test_bundle_name}"
HOSTED_TEST_BUNDLE_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/JTS Terminal.app/Contents/PlugIns/${test_bundle_name}"

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  xctest_path="${DEVELOPER_DIR}/usr/bin/xctest"
else
  xctest_path="$(xcrun --find xctest)"
fi
if [[ ! -x "${xctest_path}" ]]; then
  echo "XCTest executable not found: ${xctest_path}" >&2
  exit 2
fi

collect_descendant_pids() {
  local parent_pid="$1"
  local child_pid
  local children
  children="$(pgrep -P "${parent_pid}" 2>/dev/null || true)"
  for child_pid in ${children}; do
    collect_descendant_pids "${child_pid}"
    printf '%s\n' "${child_pid}"
  done
}

sample_process_tree() {
  local root_pid="$1"
  local phase_directory="$2"
  local descendant_pid
  local descendants

  if [[ ! -x /usr/bin/sample ]]; then
    return
  fi

  /usr/bin/sample "${root_pid}" 3 1 \
    -file "${phase_directory}/process-${root_pid}-timeout.sample.txt" >/dev/null 2>&1 || true
  descendants="$(collect_descendant_pids "${root_pid}")"
  for descendant_pid in ${descendants}; do
    /usr/bin/sample "${descendant_pid}" 3 1 \
      -file "${phase_directory}/process-${descendant_pid}-timeout.sample.txt" >/dev/null 2>&1 || true
  done
}

terminate_process_tree() {
  local signal="$1"
  local root_pid="$2"
  local descendant_pid
  local descendants

  descendants="$(collect_descendant_pids "${root_pid}")"
  for descendant_pid in ${descendants}; do
    kill "-${signal}" "${descendant_pid}" >/dev/null 2>&1 || true
  done
  kill "-${signal}" "${root_pid}" >/dev/null 2>&1 || true
}

detached_test_runner_matches() {
  local process_pid="$1"
  local expected_uid="$2"
  local runner_path="$3"
  local observed_uid
  local observed_command

  while read -r observed_uid observed_command; do
    [[ "${observed_uid}" == "${expected_uid}" ]] || return 1
    case "${observed_command}" in
      "${runner_path}"|"${runner_path} "*)
        return 0
        ;;
    esac
    return 1
  done < <(/bin/ps -ww -p "${process_pid}" -o uid=,command= 2>/dev/null)
  return 1
}

terminate_detached_test_runners() {
  local products_directory="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}"
  local current_uid
  local runner_path
  local process_pid
  local process_uid
  local process_command
  local attempt

  [[ -d "${products_directory}" ]] || return 0
  current_uid="$(/usr/bin/id -u)"

  while IFS= read -r -d '' runner_path; do
    while read -r process_pid process_uid process_command; do
      [[ "${process_uid}" == "${current_uid}" ]] || continue
      case "${process_command}" in
        "${runner_path}"|"${runner_path} "*)
          detached_test_runner_matches \
            "${process_pid}" "${current_uid}" "${runner_path}" || continue
          echo "Stopping detached TestManager runner ${process_pid}: ${runner_path}" >&2
          /bin/kill -TERM "${process_pid}" >/dev/null 2>&1 || true
          for attempt in 1 2 3 4 5; do
            if ! detached_test_runner_matches \
              "${process_pid}" "${current_uid}" "${runner_path}"; then
              break
            fi
            /bin/sleep 1
          done
          if detached_test_runner_matches \
            "${process_pid}" "${current_uid}" "${runner_path}"; then
            /bin/kill -KILL "${process_pid}" >/dev/null 2>&1 || true
          fi
          ;;
      esac
    done < <(/bin/ps -ww -axo pid=,uid=,command=)
  done < <(
    /usr/bin/find "${products_directory}" -type f \
      -path '*/UITests-Runner.app/Contents/MacOS/*UITests-Runner' \
      -perm -u+x -print0 2>/dev/null
  )
}

run_with_watchdog() {
  local phase_name="$1"
  local timeout_seconds="$2"
  shift 2

  local phase_directory="${run_directory}/${phase_name}"
  local log_path="${phase_directory}/${phase_name}.log"
  local timeout_marker="${phase_directory}/timed-out"
  local output_fifo="${phase_directory}/output.fifo"
  local command_status

  mkdir -p "${phase_directory}"
  mkfifo "${output_fifo}"

  echo
  echo "== ${phase_name} =="
  printf "Command:"
  printf " %q" "$@"
  printf "\n"

  /usr/bin/tee "${log_path}" < "${output_fifo}" &
  ACTIVE_TEE_PID=$!
  ACTIVE_FIFO="${output_fifo}"

  "$@" > "${output_fifo}" 2>&1 &
  ACTIVE_COMMAND_PID=$!

  (
    sleep "${timeout_seconds}"
    if ! kill -0 "${ACTIVE_COMMAND_PID}" 2>/dev/null; then
      exit 0
    fi

    echo "${phase_name} exceeded ${timeout_seconds}s; collecting process samples." >&2
    printf '%s\n' "${ACTIVE_COMMAND_PID}" > "${timeout_marker}"
    sample_process_tree "${ACTIVE_COMMAND_PID}" "${phase_directory}"
    terminate_process_tree TERM "${ACTIVE_COMMAND_PID}"
    sleep 5
    terminate_process_tree KILL "${ACTIVE_COMMAND_PID}"
  ) &
  ACTIVE_WATCHDOG_PID=$!

  set +e
  wait "${ACTIVE_COMMAND_PID}"
  command_status=$?
  set -e
  ACTIVE_COMMAND_PID=""

  terminate_process_tree TERM "${ACTIVE_WATCHDOG_PID}"
  wait "${ACTIVE_WATCHDOG_PID}" >/dev/null 2>&1 || true
  ACTIVE_WATCHDOG_PID=""

  wait "${ACTIVE_TEE_PID}" >/dev/null 2>&1 || true
  ACTIVE_TEE_PID=""
  rm -f "${ACTIVE_FIFO}"
  ACTIVE_FIFO=""

  if [[ -f "${timeout_marker}" ]]; then
    echo "${phase_name} timed out. Diagnostics: ${phase_directory}" >&2
    return 124
  fi

  if (( command_status != 0 )); then
    echo "${phase_name} failed with status ${command_status}. Log: ${log_path}" >&2
    return "${command_status}"
  fi

  echo "${phase_name} passed. Log: ${log_path}"
  return 0
}

common_xcodebuild_arguments=(
  -project "${PROJECT}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -destination "${DESTINATION}"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  -enableCodeCoverage NO
  SDK_STAT_CACHE_ENABLE=NO
)

if (( ONLY_TESTING_COUNT > 0 )); then
  common_xcodebuild_arguments+=("${ONLY_TESTING_ARGUMENTS[@]}")
else
  common_xcodebuild_arguments+=(-only-testing:JTSTerminalRDP2Tests)
fi

if (( DISABLE_CODE_SIGNING )); then
  common_xcodebuild_arguments+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    "CODE_SIGN_IDENTITY="
    "DEVELOPMENT_TEAM="
  )
fi

if (( EXTRA_XCODEBUILD_ARGUMENT_COUNT > 0 )); then
  common_xcodebuild_arguments+=("${EXTRA_XCODEBUILD_ARGUMENTS[@]}")
fi

echo "macOS test artifacts: ${run_directory}"
echo "DerivedData: ${DERIVED_DATA_PATH}"
echo "Direct XCTest bundle candidate: ${TEST_BUNDLE_PATH}"
if (( DISABLE_CODE_SIGNING )); then
  echo "Code signing: disabled for diagnostics"
else
  echo "Code signing: project defaults"
fi

if (( ONLY_TESTING_COUNT > 0 )); then
  # Xcode owns Swift Testing selection as well as XCTest selection. -XCTest on
  # the direct runner alone does not reliably limit Swift Testing suites.
  selected_test_command=(
    xcodebuild "${common_xcodebuild_arguments[@]}"
    -resultBundlePath "${RESULT_BUNDLE_PATH}"
    -test-timeouts-enabled YES
    -default-test-execution-time-allowance "${TEST_TIMEOUT_SECONDS}"
    -maximum-test-execution-time-allowance "${MAXIMUM_TEST_TIMEOUT_SECONDS}"
    test
  )
  TEST_BUILD_STARTED=1
  run_with_watchdog "selected-tests" \
    "$((BUILD_TIMEOUT_SECONDS + TESTMANAGER_TIMEOUT_SECONDS))" \
    "${selected_test_command[@]}"
  xcrun xcresulttool get test-results summary --path "${RESULT_BUNDLE_PATH}" |
    /usr/bin/python3 -c '
import json, sys
result = json.load(sys.stdin)
total = result.get("totalTestCount", 0)
if not (result.get("result") == "Passed" and total > 0
        and result.get("passedTests") == total):
    sys.exit("Selected tests did not all execute and pass; check the selector and xcresult.")
print(f"Selected test result: {total} passed.")
'
  echo "Selected unit tests passed. No duplicate direct or supplemental run was performed."
  exit 0
fi

build_command=(xcodebuild "${common_xcodebuild_arguments[@]}" build-for-testing)
TEST_BUILD_STARTED=1
build_status=0
run_with_watchdog "build-for-testing" "${BUILD_TIMEOUT_SECONDS}" "${build_command[@]}" || build_status=$?
if (( build_status != 0 )); then
  echo "Authoritative unit gate not run because build-for-testing failed." >&2
  exit "${build_status}"
fi

if [[ ! -d "${TEST_BUNDLE_PATH}" ]] &&
   [[ -d "${HOSTED_TEST_BUNDLE_PATH}" ]]; then
  TEST_BUNDLE_PATH="${HOSTED_TEST_BUNDLE_PATH}"
fi
if [[ ! -d "${TEST_BUNDLE_PATH}" ]]; then
  echo "Built XCTest bundle not found: ${TEST_BUNDLE_PATH}" >&2
  exit 2
fi
echo "Resolved direct XCTest bundle: ${TEST_BUNDLE_PATH}"

# Keep unrelated shell credentials and service tokens out of the test process.
# HOME/TMPDIR remain available because XCTest and Foundation need normal macOS
# per-user paths; the project tests do not require the caller's full environment.
direct_test_command=(
  env -i
  "HOME=${HOME}"
  "USER=${USER:-$(id -un)}"
  "LOGNAME=${LOGNAME:-${USER:-$(id -un)}}"
  "TMPDIR=${TMPDIR:-/tmp}"
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
  "LANG=${LANG:-en_US.UTF-8}"
)
case "${DESTINATION}" in
  *arch=x86_64*)
    direct_test_command+=(/usr/bin/arch -x86_64)
    ;;
esac
direct_test_command+=("${xctest_path}" "${TEST_BUNDLE_PATH}")

direct_status=0
run_with_watchdog "direct-xctest" "${DIRECT_TIMEOUT_SECONDS}" "${direct_test_command[@]}" || direct_status=$?
if (( direct_status != 0 )); then
  echo "Authoritative direct XCTest unit gate failed; no pass is reported." >&2
  exit "${direct_status}"
fi

if (( ! RUN_TESTMANAGER )); then
  echo
  echo "Authoritative direct XCTest unit gate passed."
  echo "Supplemental TestManager diagnostics were skipped."
  exit 0
fi

testmanager_command=(
  xcodebuild
  "${common_xcodebuild_arguments[@]}"
  -resultBundlePath "${RESULT_BUNDLE_PATH}"
  -test-timeouts-enabled YES
  -default-test-execution-time-allowance "${TEST_TIMEOUT_SECONDS}"
  -maximum-test-execution-time-allowance "${MAXIMUM_TEST_TIMEOUT_SECONDS}"
  test-without-building
)

testmanager_status=0
run_with_watchdog \
  "testmanager-diagnostic" \
  "${TESTMANAGER_TIMEOUT_SECONDS}" \
  "${testmanager_command[@]}" || testmanager_status=$?
terminate_detached_test_runners

echo
echo "Authoritative direct XCTest unit gate passed."
if (( testmanager_status == 0 )); then
  echo "Supplemental Xcode TestManager diagnostic passed."
  echo "Result bundle: ${RESULT_BUNDLE_PATH}"
  exit 0
fi

echo "Supplemental Xcode TestManager diagnostic did not pass (status ${testmanager_status})." >&2
echo "The unit gate passed, but this is not reported as a full TestManager pass." >&2
echo "Diagnostics: ${run_directory}" >&2
if (( REQUIRE_TESTMANAGER || testmanager_status != 124 )); then
  exit "${testmanager_status}"
fi
exit 0
