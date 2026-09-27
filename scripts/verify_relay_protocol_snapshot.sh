#!/usr/bin/env bash
set -euo pipefail
jts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
jts_snapshot="$jts_root/Protocols/JTSRelay/1.0.0-alpha.1"
cd "$jts_snapshot"
if command -v sha256sum >/dev/null; then sha256sum --check SHA256SUMS; else shasum -a 256 --check SHA256SUMS; fi
cmp v1/fixtures/auth-presence.json "$jts_root/Packages/JTSCompanionTransport/Tests/JTSCompanionTransportTests/Fixtures/auth-presence.json"
cd "$jts_root/Protocols/JTSRelay/1.0.0-enrollment.1"
if command -v sha256sum >/dev/null; then sha256sum --check SHA256SUMS; else shasum -a 256 --check SHA256SUMS; fi
cmp enrollment-v1/fixtures/enrollment.json "$jts_root/Packages/JTSCompanionTransport/Tests/JTSRelayEnrollmentTests/Fixtures/enrollment.json"
cmp enrollment-v1/fixtures/enrollment.json "$jts_root/Packages/JTSCompanionTransport/Tests/JTSCompanionDevicesTests/Fixtures/enrollment.json"
cd "$jts_root/Protocols/JTSRelay/2.0.0-security.1"
if command -v sha256sum >/dev/null; then sha256sum --check SHA256SUMS; else shasum -a 256 --check SHA256SUMS; fi
cd security-v2
if command -v sha256sum >/dev/null; then sha256sum --check SHA256SUMS; else shasum -a 256 --check SHA256SUMS; fi
for jts_fixture in auth-v2 confirmation-v2 revocation-v2; do
    cmp "fixtures/$jts_fixture.json" "$jts_root/Packages/JTSCompanionTransport/Tests/JTSRelayEnrollmentTests/Fixtures/$jts_fixture.json"
done
cmp fixtures/confirmation-v2.json "$jts_root/Packages/JTSCompanionTransport/Tests/JTSCompanionDevicesTests/Fixtures/confirmation-v2.json"
echo 'Relay protocol snapshot and Swift public fixture: PASS'
