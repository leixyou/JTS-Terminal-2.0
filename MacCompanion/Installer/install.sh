#!/bin/bash
set -euo pipefail
export LANG=C LC_ALL=C
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

script_dir="$(cd "$(dirname "$0")" && pwd)"
package_path="$script_dir/JTS-Mac-Companion.pkg"
app_path="/Applications/JTS Mac Companion.app"
no_launch=0
verify_only=0
allow_unsigned=0

usage() {
    cat <<'USAGE'
Usage: sudo bash install.sh [--package PATH] [--no-launch] [--verify-only] [--allow-unsigned]
Installs the local JTS Mac Companion PKG on macOS 14 or later.
Unsigned development packages require the explicit --allow-unsigned option.
--verify-only validates without installing and does not require sudo.
USAGE
}
fail() { echo "Error: $*" >&2; exit 1; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --package) [[ $# -ge 2 && -n "$2" ]] || fail "Missing --package path."; package_path="$2"; shift 2 ;;
        --no-launch) no_launch=1; shift ;;
        --verify-only) verify_only=1; shift ;;
        --allow-unsigned) allow_unsigned=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fail "Unknown option: $1" ;;
    esac
done
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail "This installer requires macOS."
os_version="$(/usr/bin/sw_vers -productVersion)"
os_major="${os_version%%.*}"
[[ "$os_major" =~ ^[0-9]+$ && "$os_major" -ge 14 ]] || fail "macOS 14 or later is required (found $os_version)."
if [[ "$verify_only" == 0 && "$(/usr/bin/id -u)" != 0 ]]; then fail "Run installation with sudo bash install.sh."; fi
[[ -f "$package_path" && -r "$package_path" && "$package_path" == *.pkg ]] || fail "Readable local PKG not found: $package_path"

# Install a private snapshot of the verified package, preventing replacement after verification.
work_dir="$(/usr/bin/mktemp -d /private/tmp/jtsmac-install.XXXXXX)"
trap '/bin/rm -rf "$work_dir"' EXIT
/bin/chmod 700 "$work_dir"
cached_package="$work_dir/JTS-Mac-Companion.pkg"
/bin/cp "$package_path" "$cached_package"
signature_status=0
signature_output="$(/usr/sbin/pkgutil --check-signature "$cached_package" 2>&1)" || signature_status=$?
unsigned=0
if [[ "$signature_output" == *"Status: no signature"* ]]; then
    [[ "$allow_unsigned" == 1 ]] || fail "The PKG is unsigned. For a trusted development build only, pass --allow-unsigned."
    unsigned=1
    echo "Development mode: explicit unsigned-package installation enabled."
elif [[ "$signature_status" != 0 || "$signature_output" != *"Status: signed by a developer certificate issued by Apple for distribution"* ]]; then
    fail "Package signature is invalid, corrupt, expired or untrusted."
fi
if [[ "$unsigned" == 0 ]]; then
    /usr/sbin/spctl --assess --type install "$cached_package" || fail "macOS rejected this package. Use a notarized, trusted distribution."
fi

expanded="$work_dir/expanded"
/usr/sbin/pkgutil --expand-full "$cached_package" "$expanded" || fail "The package could not be expanded; it is corrupt or unsupported."
component="$expanded/MacCompanion.pkg"
[[ -f "$expanded/Distribution" && -f "$component/PackageInfo" ]] || fail "This is not a JTS Mac Companion product package."
# The product archive may only select its single internal component. Refuse executable
# Distribution expressions, external package URLs, entities and unexpected XML elements.
if /usr/bin/grep -Eq '<!DOCTYPE|<!ENTITY' "$expanded/Distribution" "$component/PackageInfo"; then
    fail "Installer XML must not define external entities."
fi
distribution_safe="$(/usr/bin/xmllint --nonet --xpath '
    boolean(count(/installer-gui-script) = 1
    and count(//*[not(self::installer-gui-script or self::title or self::options or self::domains
      or self::allowed-os-versions or self::os-version or self::choices-outline or self::line
      or self::choice or self::pkg-ref or self::bundle-version or self::bundle)]) = 0
    and count(//@*[not(name() = "minSpecVersion" or name() = "customize" or name() = "require-scripts"
      or name() = "hostArchitectures" or name() = "enable_anywhere" or name() = "enable_currentUserHome"
      or name() = "enable_localSystem" or name() = "min" or name() = "max" or name() = "choice"
      or name() = "id" or name() = "visible" or name() = "title" or name() = "auth"
      or name() = "version" or name() = "installKBytes" or name() = "updateKBytes"
      or name() = "CFBundleShortVersionString" or name() = "CFBundleVersion" or name() = "path")]) = 0
    and count(/installer-gui-script/options[@customize="never" and @require-scripts="false"]) = 1
    and count(/installer-gui-script/domains[@enable_anywhere="false" and @enable_currentUserHome="false"
      and @enable_localSystem="true"]) = 1
    and count(/installer-gui-script/allowed-os-versions/os-version[@min="14.0"]) = 1
    and count(/installer-gui-script/choices-outline/line[@choice="companion"]) = 1
    and count(/installer-gui-script/choice[@id="companion"]) = 1
    and count(//pkg-ref) >= 2
    and count(//pkg-ref) <= 3
    and count(//pkg-ref[not(@id="com.jtstools.mac-companion")]) = 0
    and count(/installer-gui-script/pkg-ref[@auth="Root" and
      (normalize-space(.)="MacCompanion.pkg" or normalize-space(.)="#MacCompanion.pkg")]) = 1
    and count(//pkg-ref[normalize-space(.)!="" and normalize-space(.)!="MacCompanion.pkg"
      and normalize-space(.)!="#MacCompanion.pkg"]) = 0
    and count(//bundle) <= 1
    and count(//bundle[not(@id="com.jtstools.mac-companion" and @path="JTS Mac Companion.app")]) = 0)
    ' "$expanded/Distribution")" || fail "Invalid installer distribution XML."
[[ "$distribution_safe" == true ]] || fail "Unexpected or executable installer distribution."
package_count="$(/usr/bin/find "$expanded" -name PackageInfo -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$package_count" == 1 ]] || fail "Unexpected installer components."
package_identifier="$(/usr/bin/xmllint --xpath 'string(/pkg-info/@identifier)' "$component/PackageInfo")"
install_location="$(/usr/bin/xmllint --xpath 'string(/pkg-info/@install-location)' "$component/PackageInfo")"
[[ "$package_identifier" == com.jtstools.mac-companion && "$install_location" == /Applications ]] || fail "Unexpected package identity or destination."
[[ ! -e "$component/Scripts" ]] || fail "Unexpected privileged installer scripts."
payload_app="$component/Payload/JTS Mac Companion.app"
payload_count="$(/usr/bin/find "$component/Payload" -mindepth 1 -maxdepth 1 | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$payload_count" == 1 && -d "$payload_app" && ! -L "$payload_app" ]] || fail "Unexpected package payload."
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$payload_app/Contents/Info.plist")"
[[ "$bundle_id" == com.jtstools.mac-companion ]] || fail "Unexpected application identity."
/usr/bin/codesign --verify --strict "$payload_app" || fail "The application signature is invalid or its files are corrupt."
echo "Verified JTS Mac Companion package for macOS $os_version."
if [[ "$verify_only" == 1 ]]; then echo "Verification complete; nothing was installed."; exit 0; fi

running_companions="$(/bin/ps -axo comm= | /usr/bin/awk '$0 ~ /(^|\/)JTSMacCompanion$/ {print}')" || fail "Unable to inspect running applications."
[[ -z "$running_companions" ]] || fail "JTS Mac Companion is running. Quit it in every logged-in user session, then retry installation; no application was overwritten."
/usr/sbin/installer -pkg "$cached_package" -target / || fail "macOS Installer failed; inspect /var/log/install.log."
[[ -d "$app_path" && ! -L "$app_path" ]] || fail "Installer returned success but the application is missing."
/usr/bin/codesign --verify --strict "$app_path" || fail "Installed application verification failed."
echo "Installation complete: $app_path"
if [[ "$no_launch" == 1 ]]; then echo "Open JTS Mac Companion after logging in to complete setup."; exit 0; fi

console_user="$(/usr/bin/stat -f %Su /dev/console)"
case "$console_user" in root|loginwindow|_mbsetupuser|"") echo "No logged-in desktop user; open JTS Mac Companion after login."; exit 0 ;; esac
console_uid="$(/usr/bin/id -u "$console_user")"
if [[ ! "$console_uid" =~ ^[0-9]+$ || "$console_uid" -lt 500 ]] || ! /bin/launchctl print "gui/$console_uid" >/dev/null 2>&1; then
    echo "No active GUI session; open JTS Mac Companion after login."; exit 0
fi
if /bin/launchctl asuser "$console_uid" /usr/bin/sudo -H -u "$console_user" /usr/bin/open "$app_path" --args --onboarding; then
    echo "Setup launch requested for desktop user $console_user. Grant Screen Recording and, for control, Accessibility in System Settings."
else
    echo "Installed successfully, but setup could not be opened. Open JTS Mac Companion from Applications after login." >&2
    exit 3
fi
