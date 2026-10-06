#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${JTS_COMPANION_OUTPUT_DIR:-$project_root/build/MacCompanion}"
app_identity="${JTS_COMPANION_SIGNING_IDENTITY:--}"
installer_identity="${JTS_COMPANION_INSTALLER_SIGNING_IDENTITY:-}"
configuration="${JTS_COMPANION_CONFIGURATION:-release}"
native_only="${JTS_COMPANION_NATIVE_ONLY:-0}"
make_dmg=1

usage() {
    cat <<'USAGE'
Usage: bash scripts/build_mac_companion.sh [options]
  --output-dir PATH                 Preserve artifacts in this directory.
  --app-signing-identity NAME        Developer ID Application identity; default ad-hoc (-).
  --installer-signing-identity NAME  Developer ID Installer identity; default unsigned PKG.
  --configuration debug|release     Default release.
  --native-only                     Build only the current architecture.
  --skip-dmg                        Build App and PKG without the optional DMG.
USAGE
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir|--app-signing-identity|--installer-signing-identity|--configuration)
            [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; exit 2; }
            case "$1" in
                --output-dir) output_dir="$2" ;;
                --app-signing-identity) app_identity="$2" ;;
                --installer-signing-identity) installer_identity="$2" ;;
                --configuration) configuration="$2" ;;
            esac
            shift 2 ;;
        --native-only) native_only=1; shift ;;
        --skip-dmg) make_dmg=0; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ "$configuration" == release || "$configuration" == debug ]] || { echo "Invalid configuration" >&2; exit 2; }
if [[ "$app_identity" != - && "$app_identity" != "Developer ID Application:"* ]]; then
    echo "Use a Developer ID Application identity for distribution." >&2; exit 2
fi
if [[ -n "$installer_identity" && "$installer_identity" != "Developer ID Installer:"* ]]; then
    echo "Use a Developer ID Installer identity for the PKG." >&2; exit 2
fi
if [[ -n "$installer_identity" && "$app_identity" == - ]]; then
    echo "A release Installer signature also requires a Developer ID Application signature." >&2; exit 2
fi
architectures=(--arch arm64 --arch x86_64)
if [[ "$native_only" == "1" ]]; then architectures=(); fi

swift build --package-path "$project_root/MacCompanion" --configuration "$configuration" "${architectures[@]}"
binary_dir="$(swift build --package-path "$project_root/MacCompanion" --configuration "$configuration" "${architectures[@]}" --show-bin-path)"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.companion-staging.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
artifact_dir="$(mktemp -d "$output_dir/JTS-Mac-Companion-$(date +%Y%m%d-%H%M%S).XXXXXX")"
app_path="$staging_dir/payload/JTS Mac Companion.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/JTSMacCompanion" "$app_path/Contents/MacOS/JTSMacCompanion"
cp "$project_root/MacCompanion/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_root/MacCompanion/Resources/PrivacyInfo.xcprivacy" "$app_path/Contents/Resources/PrivacyInfo.xcprivacy"
# Standalone host statically links the checkout's audited OpenSSL archive.
for notice in FreeRDP-Apache-2.0.txt OpenSSL-Apache-2.0.txt FreeRDP-cpufeatures-NOTICE.txt; do
    cp "$project_root/Vendor/FreeRDP/Licenses/$notice" "$app_path/Contents/Resources/$notice"
done
cp "$project_root/Vendor/FreeRDP/sbom.cdx.json" "$app_path/Contents/Resources/sbom.cdx.json"
find "$app_path" -type d -exec chmod 755 {} +
find "$app_path" -type f -exec chmod 644 {} +
chmod 755 "$app_path/Contents/MacOS/JTSMacCompanion"
codesign_args=(--force --options runtime --sign "$app_identity")
if [[ "$app_identity" != - ]]; then codesign_args+=(--timestamp); fi
/usr/bin/codesign "${codesign_args[@]}" "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"

component_pkg="$staging_dir/MacCompanion.pkg"
/usr/bin/pkgbuild --root "$staging_dir/payload" --component-plist "$project_root/MacCompanion/Installer/Components.plist" \
    --identifier com.jtstools.mac-companion --version "$version" --install-location /Applications \
    --ownership recommended "$component_pkg"
pkg_path="$artifact_dir/JTS-Mac-Companion.pkg"
product_args=(--distribution "$project_root/MacCompanion/Installer/Distribution.xml" --package-path "$staging_dir")
if [[ -n "$installer_identity" ]]; then product_args+=(--sign "$installer_identity" --timestamp); fi
/usr/bin/productbuild "${product_args[@]}" "$pkg_path"
/usr/bin/ditto "$app_path" "$artifact_dir/JTS Mac Companion.app"
cp "$project_root/MacCompanion/Installer/install.sh" "$artifact_dir/install.sh"
cp "$project_root/docs/INSTALL_MAC_COMPANION.md" "$artifact_dir/INSTALL_MAC_COMPANION.md"
chmod 755 "$artifact_dir/install.sh"

if [[ "$make_dmg" == 1 ]]; then
    dmg_staging="$staging_dir/dmg"
    mkdir "$dmg_staging"
    /usr/bin/ditto "$app_path" "$dmg_staging/JTS Mac Companion.app"
    ln -s /Applications "$dmg_staging/Applications"
    cp "$pkg_path" "$dmg_staging/JTS-Mac-Companion.pkg"
    cp "$artifact_dir/install.sh" "$dmg_staging/install.sh"
    cp "$artifact_dir/INSTALL_MAC_COMPANION.md" "$dmg_staging/INSTALL_MAC_COMPANION.md"
    /usr/bin/hdiutil create -volname "JTS Mac Companion" -srcfolder "$dmg_staging" -format UDZO "$artifact_dir/JTS-Mac-Companion.dmg"
    if [[ "$app_identity" != - ]]; then /usr/bin/codesign --sign "$app_identity" --timestamp "$artifact_dir/JTS-Mac-Companion.dmg"; fi
fi
(
    cd "$artifact_dir"
    checksum_files=(JTS-Mac-Companion.pkg install.sh INSTALL_MAC_COMPANION.md)
    if [[ -f JTS-Mac-Companion.dmg ]]; then checksum_files+=(JTS-Mac-Companion.dmg); fi
    /usr/bin/shasum -a 256 "${checksum_files[@]}" > SHA256SUMS
)
/usr/bin/ditto -c -k --keepParent "$artifact_dir" "$artifact_dir.zip"
(cd "$(dirname "$artifact_dir")"; /usr/bin/shasum -a 256 "$(basename "$artifact_dir").zip" > "$(basename "$artifact_dir").zip.sha256")
if [[ -z "$installer_identity" ]]; then
    echo "Development PKG: unsigned. Installation requires explicit --allow-unsigned."
else
    echo "Signed PKG: notarize and staple before distributing; regenerate ZIP and checksums after stapling."
fi
printf 'Artifacts: %s\nPKG: %s\nInstaller: %s/install.sh\nTransfer ZIP: %s.zip\n' "$artifact_dir" "$pkg_path" "$artifact_dir" "$artifact_dir"
