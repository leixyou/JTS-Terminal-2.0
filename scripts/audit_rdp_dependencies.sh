#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_SCRIPT="scripts/build_freerdp.sh"
VENDOR_DIR="Vendor/FreeRDP"
MODE="release"
ONLINE=1
failures=0
warnings=0

extract_assignment() {
    local key="$1"
    sed -n "s/^${key}=\"\([^\"]*\)\"$/\\1/p" "$BUILD_SCRIPT" | head -n 1
}

FREERDP_VERSION="$(extract_assignment FREERDP_VERSION)"
FREERDP_SHA256="$(extract_assignment FREERDP_SHA256)"
OPENSSL_VERSION="$(extract_assignment OPENSSL_VERSION)"
OPENSSL_SHA256="$(extract_assignment OPENSSL_SHA256)"

usage() {
    cat <<'EOF'
Usage: scripts/audit_rdp_dependencies.sh [--source-only] [--offline]

Release mode (the default) requires the built FreeRDP XCFramework, license
notices, CycloneDX SBOM, and a live NVD CVE query. --source-only validates the
pinned build recipe before the binary dependency has been built. --offline
skips the live CVE query and therefore is not sufficient evidence for release.
The exact-CPE lookup is one evidence source, not a complete advisory inventory:
review current upstream FreeRDP/OpenSSL advisories as well, especially records
not yet assigned a CPE. Incomplete or unanalyzed returned records fail closed.
EOF
}

for argument in "$@"; do
    case "$argument" in
        --source-only) MODE="source-only" ;;
        --offline) ONLINE=0 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
    esac
done

pass() {
    printf 'PASS: %s\n' "$1"
}

warn() {
    printf 'WARN: %s\n' "$1" >&2
    warnings=$((warnings + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

require_command() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "Required command is available: $1"
    else
        fail "Required command is missing: $1"
    fi
}

require_text() {
    local file="$1"
    local literal="$2"
    local description="$3"
    if [[ -f "$file" ]] && rg -F -q -- "$literal" "$file"; then
        pass "$description"
    else
        fail "$description"
    fi
}

require_file() {
    local file="$1"
    local description="$2"
    if [[ -f "$file" ]]; then
        pass "$description"
    else
        fail "$description"
    fi
}

for command_name in rg python3 shasum; do
    require_command "$command_name"
done
if (( ONLINE == 1 )); then
    require_command curl
fi

if [[ "$FREERDP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "FreeRDP version is pinned: $FREERDP_VERSION"
else
    fail 'FreeRDP version is missing or malformed'
fi
if [[ "$FREERDP_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    pass 'FreeRDP source archive SHA-256 is pinned'
else
    fail 'FreeRDP source archive SHA-256 is missing or malformed'
fi
if [[ -n "$OPENSSL_VERSION" ]]; then
    pass "OpenSSL version is pinned: $OPENSSL_VERSION"
else
    fail 'OpenSSL version is not pinned'
fi
if [[ "$OPENSSL_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    pass 'OpenSSL source archive SHA-256 is pinned'
else
    fail 'OpenSSL source archive SHA-256 is missing or malformed'
fi
require_text "$BUILD_SCRIPT" '-DBUILD_SHARED_LIBS=OFF' 'FreeRDP recipe builds static libraries'
require_text "$BUILD_SCRIPT" '-DCHANNEL_DRDYNVC=ON' 'FreeRDP recipe includes Dynamic Virtual Channels'
require_text "$BUILD_SCRIPT" '-DCHANNEL_CLIPRDR=ON' 'Bounded text clipboard redirection is included'
require_text "$BUILD_SCRIPT" '-DCHANNEL_DRIVE=OFF' 'Drive redirection is excluded by default'
require_text "$BUILD_SCRIPT" '-DCHANNEL_AUDIN=OFF' 'Microphone redirection is excluded by default'
require_text "$BUILD_SCRIPT" '-DCHANNEL_PRINTER=OFF' 'Printer redirection is excluded by default'
require_text "$BUILD_SCRIPT" '-DCHANNEL_SMARTCARD=OFF' 'Smart-card redirection is excluded by default'
require_text "$BUILD_SCRIPT" '-DCHANNEL_URBDRC=OFF' 'USB redirection is excluded by default'

for archive in \
    "build/freerdp-$FREERDP_VERSION/downloads/freerdp-$FREERDP_VERSION.tar.gz" \
    "build/freerdp-$FREERDP_VERSION/downloads/openssl-$OPENSSL_VERSION.tar.gz"; do
    if [[ -f "$archive" ]]; then
        case "$archive" in
            *openssl*) expected="$OPENSSL_SHA256" ;;
            *freerdp*) expected="$FREERDP_SHA256" ;;
        esac
        actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
        if [[ "$actual" == "$expected" ]]; then
            pass "Downloaded source checksum matches: $archive"
        else
            fail "Downloaded source checksum mismatch: $archive"
        fi
    fi
done

if [[ "$MODE" == "release" ]]; then
    require_file "$VENDOR_DIR/JTFreeRDP.xcframework/Info.plist" 'Built FreeRDP XCFramework is present'
    require_file "$VENDOR_DIR/Licenses/FreeRDP-Apache-2.0.txt" 'FreeRDP Apache-2.0 notice is present'
    require_file "$VENDOR_DIR/Licenses/FreeRDP-cpufeatures-NOTICE.txt" 'FreeRDP cpufeatures NOTICE is present'
    require_file "$VENDOR_DIR/Licenses/OpenSSL-Apache-2.0.txt" 'OpenSSL Apache-2.0 notice is present'
    require_file "$VENDOR_DIR/sbom.cdx.json" 'CycloneDX SBOM is present'

    if [[ -f "$VENDOR_DIR/sbom.cdx.json" ]]; then
        if python3 - "$VENDOR_DIR/sbom.cdx.json" "$FREERDP_VERSION" "$FREERDP_SHA256" "$OPENSSL_VERSION" "$OPENSSL_SHA256" <<'PY'
import json
import sys

path, freerdp_version, freerdp_sha256, openssl_version, openssl_sha256 = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)

assert document.get("bomFormat") == "CycloneDX"
components = {
    (component.get("name"), component.get("version")): component
    for component in document.get("components", [])
}
for key, expected_hash in ((("FreeRDP", freerdp_version), freerdp_sha256), (("OpenSSL", openssl_version), openssl_sha256)):
    assert key in components, f"missing component {key[0]} {key[1]}"
    licenses = components[key].get("licenses", [])
    assert any(item.get("license", {}).get("id") == "Apache-2.0" for item in licenses)
    hashes = components[key].get("hashes", [])
    assert any(item.get("alg") == "SHA-256" and item.get("content") == expected_hash for item in hashes)
PY
        then
            pass 'SBOM contains pinned FreeRDP/OpenSSL versions, licenses, and hashes'
        else
            fail 'SBOM is missing required component, license, or hash metadata'
        fi
    fi

    if [[ -d "$VENDOR_DIR/JTFreeRDP.xcframework" ]]; then
        if [[ -n "$(find "$VENDOR_DIR/JTFreeRDP.xcframework" -type f -name '*.dylib' -print -quit)" ]]; then
            fail 'FreeRDP XCFramework must not contain dynamic libraries'
        else
            pass 'FreeRDP XCFramework contains no dynamic libraries'
        fi
    fi
else
    warn 'Source-only mode does not prove the XCFramework, notices, or SBOM are release-ready'
fi

query_nvd() {
    local component="$1"
    local version="$2"
    local cpe="$3"
    local output_dir="$4"
    local encoded_cpe
    encoded_cpe="$(python3 - "$cpe" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
)"
    local component_slug
    component_slug="$(printf '%s' "$component" | tr '[:upper:]' '[:lower:]')"
    local destination="$output_dir/$component_slug-${version}-nvd.json"
    local query_url="https://services.nvd.nist.gov/rest/json/cves/2.0?cpeName=$encoded_cpe"
    local curl_status

    if [[ -n "${NVD_API_KEY:-}" ]]; then
        curl_status=0
        curl \
            --fail \
            --silent \
            --show-error \
            --retry 3 \
            --connect-timeout 15 \
            --max-time 90 \
            -H "apiKey: $NVD_API_KEY" \
            "$query_url" \
            -o "$destination" || curl_status=$?
    else
        curl_status=0
        curl \
            --fail \
            --silent \
            --show-error \
            --retry 3 \
            --connect-timeout 15 \
            --max-time 90 \
            "$query_url" \
            -o "$destination" || curl_status=$?
    fi
    if (( curl_status != 0 )); then
        fail "NVD query failed for $component $version"
        return
    fi

    if python3 scripts/lib/nvd_cve_review.py "$component" "$version" "$cpe" "$destination"
    then
        pass "Live NVD query found no applicable or unresolved CVE records for $component $version"
    else
        fail "Live NVD query requires security review for $component $version"
    fi
}

if (( ONLINE == 1 )); then
    audit_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    audit_dir="build/security/rdp-dependency-audit/$audit_stamp"
    mkdir -p "$audit_dir"
    query_nvd 'FreeRDP' "$FREERDP_VERSION" "cpe:2.3:a:freerdp:freerdp:$FREERDP_VERSION:*:*:*:*:*:*:*" "$audit_dir"
    query_nvd 'OpenSSL' "$OPENSSL_VERSION" "cpe:2.3:a:openssl:openssl:$OPENSSL_VERSION:*:*:*:*:*:*:*" "$audit_dir"
    printf '%s\n' \
        "mode=$MODE" \
        "query_scope=exact-cpe; upstream advisories also require review" \
        "freerdp_version=$FREERDP_VERSION" \
        "openssl_version=$OPENSSL_VERSION" \
        "checked_at_utc=$audit_stamp" \
        "failures=$failures" \
        "warnings=$warnings" \
        > "$audit_dir/summary.txt"
    printf 'Audit evidence: %s\n' "$audit_dir"
else
    warn 'Live NVD CVE lookup skipped; this run is not release evidence'
fi

printf '\nRDP dependency audit completed: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
if (( failures > 0 )); then
    exit 1
fi
