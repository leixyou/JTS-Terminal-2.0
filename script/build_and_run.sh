#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="JTS Terminal"
BUNDLE_ID="com.lljts.JTSTerminal"
PROJECT_NAME="JTSTerminal.xcodeproj"
SCHEME_NAME="JTSTerminalRDP2"
CONFIGURATION="Debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/DerivedData/Run"
APP_BUNDLE="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--launch-built]" >&2
}

stop_existing_app() {
  if ! has_running_gui_app; then
    return 0
  fi

  terminate_running_gui_app TERM

  for _ in {1..20}; do
    if ! has_running_gui_app; then
      return 0
    fi
    sleep 0.25
  done

  terminate_running_gui_app KILL
}

running_gui_app_pids() {
  local pid executable args padded_args
  pgrep -x "$APP_NAME" 2>/dev/null | while read -r pid; do
    [[ -z "$pid" ]] && continue

    executable="$(ps -p "$pid" -o comm= -ww 2>/dev/null || true)"
    [[ "$executable" == "$APP_BINARY" ]] || continue
    args="$(ps -p "$pid" -o args= -ww 2>/dev/null || true)"
    padded_args=" $args "
    if [[ "$padded_args" == *" --mcp "* ]]; then
      continue
    fi

    echo "$pid"
  done
}

has_running_gui_app() {
  [[ -n "$(running_gui_app_pids)" ]]
}

terminate_running_gui_app() {
  local signal="$1"
  running_gui_app_pids | while read -r pid; do
    [[ -z "$pid" ]] && continue
    kill "-$signal" "$pid" >/dev/null 2>&1 || true
  done
}

build_app() {
  /usr/bin/python3 "$ROOT_DIR/scripts/prepare_debug_runtime.py" \
    --repo-root "$ROOT_DIR" --prepare-build

  xcodebuild \
    -scheme "$SCHEME_NAME" \
    -project "$PROJECT_NAME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    SDK_STAT_CACHE_ENABLE=NO \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build

  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Built app bundle not found: $APP_BUNDLE" >&2
    exit 1
  fi

  /usr/bin/python3 "$ROOT_DIR/scripts/prepare_debug_runtime.py" \
    --repo-root "$ROOT_DIR"
  retain_latest_products
}

retain_latest_products() {
  PYTHONPATH="$ROOT_DIR/scripts" /usr/bin/python3 \
    "$ROOT_DIR/scripts/retain_latest_debug_and_release.py" \
    --repo-root "$ROOT_DIR" \
    --keep-app "$APP_BUNDLE"
}

verify_built_app() {
  /usr/bin/python3 "$ROOT_DIR/scripts/prepare_debug_runtime.py" \
    --repo-root "$ROOT_DIR"
  retain_latest_products
}

refresh_app_registration() {
  if [[ ! -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
    echo "Built app icon not found: $APP_BUNDLE/Contents/Resources/AppIcon.icns" >&2
    exit 1
  fi

  /usr/bin/touch "$APP_BUNDLE" "$APP_BUNDLE/Contents/Info.plist"

  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi
}

open_app() {
  refresh_app_registration
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_app() {
  sleep 2
  if ! has_running_gui_app; then
    echo "$APP_NAME did not stay running after launch." >&2
    /usr/bin/log show --last 2m --style compact --predicate "process == \"$APP_NAME\"" >&2 || true
    return 1
  fi

  if ! APP_NAME="$APP_NAME" python3 - <<'PY'
import os
import sys

import Quartz

app_name = os.environ["APP_NAME"]
windows = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []
for window in windows:
    if window.get("kCGWindowOwnerName") != app_name:
        continue
    if window.get("kCGWindowLayer") == 0 and window.get("kCGWindowName"):
        print(f"{app_name} is running with visible window: {window.get('kCGWindowName')}")
        sys.exit(0)

print(f"{app_name} is running but no visible app window was found.", file=sys.stderr)
sys.exit(1)
PY
  then
    /usr/bin/log show --last 2m --style compact --predicate "process == \"$APP_NAME\"" >&2 || true
    return 1
  fi
}

case "$MODE" in
  run)
    stop_existing_app
    build_app
    open_app
    ;;
  --debug|debug)
    stop_existing_app
    build_app
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    stop_existing_app
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_existing_app
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    stop_existing_app
    build_app
    open_app
    verify_app
    ;;
  --launch-built)
    # Resume after an interrupted post-build signing step without rebuilding
    # over newly started MCP clients. The same strict signature gate still runs.
    stop_existing_app
    verify_built_app
    open_app
    verify_app
    ;;
  *)
    usage
    exit 2
    ;;
esac
