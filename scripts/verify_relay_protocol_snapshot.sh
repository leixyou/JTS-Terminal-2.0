#!/usr/bin/env bash
set -euo pipefail
jts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jts_snapshot="$jts_root/Protocols/JTSRelay/1.0.0-alpha.1"
cd "$jts_snapshot"
if command -v sha256sum >/dev/null; then sha256sum --check SHA256SUMS; else shasum -a 256 --check SHA256SUMS; fi
cmp v1/fixtures/auth-presence.json "$jts_root/Packages/JTSCompanionTransport/Tests/JTSCompanionTransportTests/Fixtures/auth-presence.json"
echo 'Relay protocol snapshot and Swift public fixture: PASS'
