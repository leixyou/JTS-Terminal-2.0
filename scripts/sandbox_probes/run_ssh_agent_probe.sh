#!/bin/bash
# Measures whether JTS Terminal's App Sandbox lets ssh use an ssh-agent.
#
# Builds a small probe app, signs it ad hoc with JTSTerminal/JTSTerminal.entitlements
# (the app's real sandbox entitlements) and runs it against ssh-agent sockets
# in the usual places. The same probe signed without entitlements is the
# unsandboxed control. For every socket the probe connects directly and also
# spawns /usr/bin/ssh-add -l, which inherits the sandbox the way JTS Terminal's
# /usr/bin/ssh children do.
#
# The user's own agent is only listed, never changed. Temporary agents, keys
# and sockets are removed on exit. macOS keeps the probe's empty container at
# ~/Library/Containers/com.lljts.JTSTerminal.SSHAgentProbe.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This probe runs on macOS only." >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
entitlements="$repo_root/JTSTerminal/JTSTerminal.entitlements"
source_file="$repo_root/scripts/sandbox_probes/ssh_agent_probe.c"
bundle_id="com.lljts.JTSTerminal.SSHAgentProbe"

inherited_socket="${SSH_AUTH_SOCK:-}"
launchd_socket="$(launchctl getenv SSH_AUTH_SOCK 2>/dev/null || true)"

# Keep paths short: a Unix socket path is limited to 104 bytes on macOS.
work="$(mktemp -d /tmp/jts-agent-probe.XXXXXX)"
launchd_style_dir="/private/tmp/com.apple.launchd.jtsprobe$$"
home_socket="$HOME/.ssh/jts-probe-$$.sock"
key_in_home="$HOME/.ssh/jts-probe-$$-key"
agent_pids=()
summary=()

cleanup() {
  for pid in ${agent_pids[@]+"${agent_pids[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  rm -rf "$work" "$launchd_style_dir"
  rm -f "$home_socket" "$key_in_home" "$key_in_home.pub"
}
trap cleanup EXIT

echo "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
echo "Inherited SSH_AUTH_SOCK: ${inherited_socket:-<unset>}"
echo "launchd SSH_AUTH_SOCK:   ${launchd_socket:-<unset>}"

# --- Build the sandboxed probe app and the unsandboxed control.
app="$work/SSHAgentProbe.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleExecutable</key><string>ssh-agent-probe</string>
  <key>CFBundleName</key><string>SSHAgentProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST
sandboxed_probe="$app/Contents/MacOS/ssh-agent-probe"
clang -O1 -Wall -o "$sandboxed_probe" "$source_file" \
  -Wl,-sectcreate,__TEXT,__info_plist,"$app/Contents/Info.plist"
codesign --force --sign - --identifier "$bundle_id" --entitlements "$entitlements" "$app"

control_probe="$work/ssh-agent-probe-control"
clang -O1 -Wall -o "$control_probe" "$source_file"
codesign --force --sign - "$control_probe"

echo
echo "Probe entitlements (from $entitlements):"
codesign -d --entitlements - "$app" 2>/dev/null | sed 's/^/  /' || true

# --- Temporary agents holding a throwaway key.
ssh-keygen -q -t ed25519 -N '' -C jts-sandbox-probe -f "$work/agent_key"
mkdir -p -m 700 "$HOME/.ssh"
cp "$work/agent_key" "$key_in_home"
chmod 600 "$key_in_home"

start_agent() {
  local socket_path="$1" output pid
  mkdir -p "$(dirname "$socket_path")"
  output="$(ssh-agent -s -a "$socket_path")"
  pid="$(printf '%s\n' "$output" | sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p')"
  agent_pids+=("$pid")
  SSH_AUTH_SOCK="$socket_path" ssh-add -q "$work/agent_key"
}

run_case() {
  local label="$1" socket_path="$2" mode binary output status line
  echo
  echo "=== $label"
  echo "    $socket_path"
  for mode in control sandboxed; do
    if [[ "$mode" == sandboxed ]]; then binary="$sandboxed_probe"; else binary="$control_probe"; fi
    echo "--- $mode"
    if output="$(SSH_AUTH_SOCK="$socket_path" "$binary" "$key_in_home" 2>&1)"; then
      status=0
    else
      status=$?
    fi
    printf '%s\n' "$output"
    line="$(printf '%s\n' "$output" | grep '^RESULT ' | tail -1 || true)"
    if [[ -z "$line" ]]; then
      line="RESULT probe exited with status $status before reporting"
    fi
    summary+=("$label | $mode | ${line#RESULT }")
  done
}

launchd_style_socket="$launchd_style_dir/Listeners"
start_agent "$launchd_style_socket"
run_case "launchd-style path (/private/tmp/com.apple.launchd.*/Listeners)" "$launchd_style_socket"

start_agent "$home_socket"
run_case "socket in ~/.ssh (IdentityAgent-style)" "$home_socket"

temporary_socket="$work/agent.sock"
start_agent "$temporary_socket"
run_case "socket in /tmp" "$temporary_socket"

if [[ -n "$launchd_socket" ]]; then
  run_case "this Mac's launchd ssh-agent (read only)" "$launchd_socket"
fi
if [[ -n "$inherited_socket" && "$inherited_socket" != "$launchd_socket" ]]; then
  run_case "inherited SSH_AUTH_SOCK (read only)" "$inherited_socket"
fi

echo
echo "=== Sandbox denials logged during the probe"
log show --last 5m --style compact \
  --predicate '(eventMessage CONTAINS "ssh-agent-probe" OR eventMessage CONTAINS "ssh-add") AND eventMessage CONTAINS "deny"' \
  2>/dev/null | tail -n 40 || true

echo
echo "=== Summary (socket = direct connect from the probe; ssh_add_exit: 0 listed, 1 empty agent, 2 unreachable)"
for row in "${summary[@]}"; do
  echo "  $row"
done
