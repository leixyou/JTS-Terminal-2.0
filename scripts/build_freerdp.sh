#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$PROJECT_DIR/Vendor/FreeRDP"
OUTPUT_XCFRAMEWORK="$OUTPUT_DIR/JTFreeRDP.xcframework"
ARCHITECTURES="${JTS_FREERDP_ARCHS:-arm64 x86_64}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

FREERDP_VERSION="3.31.1"
FREERDP_ARCHIVE="freerdp-${FREERDP_VERSION}.tar.gz"
FREERDP_URL="https://github.com/FreeRDP/FreeRDP/releases/download/${FREERDP_VERSION}/${FREERDP_ARCHIVE}"
FREERDP_SHA256="4a2629026896cb4e26fb8ed2d6ca6aa4ab89ca95528dfbae2550c2f6bc866991"
BUILD_ROOT="${JTS_FREERDP_BUILD_ROOT:-$PROJECT_DIR/build/freerdp-$FREERDP_VERSION}"

OPENSSL_VERSION="3.6.4"
OPENSSL_ARCHIVE="openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/${OPENSSL_ARCHIVE}"
OPENSSL_SHA256="9bffaa1ad1e07b354c21bd3324ec02fa15579f45a7d0494b3e74bc449b7333ef"

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing required tool: $1" >&2
        exit 1
    }
}

for tool in cmake ninja xcodebuild curl shasum tar make perl libtool ranlib nm rg patch; do
    require_tool "$tool"
done

mkdir -p "$BUILD_ROOT/downloads" "$OUTPUT_DIR"

download_and_verify() {
    local url="$1"
    local destination="$2"
    local expected_sha="$3"

    if [[ ! -f "$destination" ]]; then
        curl --fail --location --retry 3 --output "$destination" "$url"
    fi

    local actual_sha
    actual_sha="$(shasum -a 256 "$destination" | awk '{print $1}')"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "Checksum mismatch for $destination" >&2
        echo "Expected: $expected_sha" >&2
        echo "Actual:   $actual_sha" >&2
        exit 1
    fi
}

download_and_verify \
    "$FREERDP_URL" \
    "$BUILD_ROOT/downloads/$FREERDP_ARCHIVE" \
    "$FREERDP_SHA256"
download_and_verify \
    "$OPENSSL_URL" \
    "$BUILD_ROOT/downloads/$OPENSSL_ARCHIVE" \
    "$OPENSSL_SHA256"

build_openssl() {
    local arch="$1"
    local source_dir="$BUILD_ROOT/openssl-source-$arch"
    local install_dir="$BUILD_ROOT/openssl-install-$arch"
    local configure_target
    local sdk_path

    sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

    case "$arch" in
        arm64) configure_target="darwin64-arm64-cc" ;;
        x86_64) configure_target="darwin64-x86_64-cc" ;;
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
    esac

    rm -rf "$source_dir" "$install_dir"
    mkdir -p "$source_dir" "$install_dir"
    tar -xzf "$BUILD_ROOT/downloads/$OPENSSL_ARCHIVE" \
        --strip-components=1 \
        -C "$source_dir"

    (
        cd "$source_dir"
        env \
            CC="$(xcrun --find clang)" \
            CFLAGS="-arch $arch -isysroot $sdk_path -mmacosx-version-min=$DEPLOYMENT_TARGET" \
            CPPFLAGS="-isysroot $sdk_path" \
            LDFLAGS="-arch $arch -isysroot $sdk_path -mmacosx-version-min=$DEPLOYMENT_TARGET" \
            ./Configure \
                "$configure_target" \
                no-shared \
                no-tests \
                no-apps \
                no-docs \
                --prefix="$install_dir" \
                --openssldir="$install_dir/ssl"
        make -j"$(sysctl -n hw.logicalcpu)" build_libs
        make install_dev
    )
}

build_freerdp() {
    local arch="$1"
    local source_dir="$BUILD_ROOT/freerdp-source-$arch"
    local build_dir="$BUILD_ROOT/freerdp-build-$arch"
    local install_dir="$BUILD_ROOT/freerdp-install-$arch"
    local openssl_dir="$BUILD_ROOT/openssl-install-$arch"
    local combined_archive="$BUILD_ROOT/libJTFreeRDP-$arch.a"
    local headers_dir="$BUILD_ROOT/headers-$arch"

    rm -rf "$source_dir" "$build_dir" "$install_dir" "$headers_dir"
    mkdir -p "$source_dir" "$build_dir" "$install_dir" "$headers_dir"
    tar -xzf "$BUILD_ROOT/downloads/$FREERDP_ARCHIVE" \
        --strip-components=1 \
        -C "$source_dir"
    patch -d "$source_dir" -p1 --forward --batch < \
        "$PROJECT_DIR/scripts/patches/freerdp-explicit-empty-clipboard-list.patch"

    cmake \
        -S "$source_dir" \
        -B "$build_dir" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_TESTING_INTERNAL=OFF \
        -DWITH_CLIENT=ON \
        -DWITH_CLIENT_COMMON=ON \
        -DWITH_CLIENT_INTERFACE=OFF \
        -DWITH_CLIENT_SDL=OFF \
        -DWITH_CLIENT_MAC=OFF \
        -DWITH_SAMPLE=OFF \
        -DWITH_SERVER=OFF \
        -DWITH_SERVER_INTERFACE=OFF \
        -DWITH_CHANNELS=ON \
        -DWITH_CLIENT_CHANNELS=ON \
        -DWITH_SERVER_CHANNELS=OFF \
        -DWITH_OPENSSL=ON \
        -DWITH_INTERNAL_MD4=ON \
        -DWITH_INTERNAL_RC4=ON \
        -DOPENSSL_USE_STATIC_LIBS=TRUE \
        -DOPENSSL_ROOT_DIR="$openssl_dir" \
        -DWITH_AAD=OFF \
        -DWITH_WEBVIEW=OFF \
        -DWITH_KRB5=OFF \
        -DWITH_PKCS11=OFF \
        -DWITH_PCSC=OFF \
        -DWITH_CUPS=OFF \
        -DWITH_FUSE=OFF \
        -DWITH_FFMPEG=OFF \
        -DWITH_SWSCALE=OFF \
        -DWITH_OPUS=OFF \
        -DWITH_JPEG=OFF \
        -DWITH_CAIRO=OFF \
        -DWITH_MACAUDIO=OFF \
        -DWITH_OPENH264=OFF \
        -DWITH_YUV=OFF \
        -DWITH_AOM=OFF \
        -DWITH_WINPR_TOOLS=OFF \
        -DWITH_WINPR_TOOLS_CLI=OFF \
        -DWITH_MANPAGES=OFF \
        -DWITH_X11=OFF \
        -DWITH_URIPARSER=OFF \
        -DWITH_JSON_DISABLED=ON \
        -DWITH_SIMD=OFF \
        -DCHANNEL_AINPUT=OFF \
        -DCHANNEL_AUDIN=OFF \
        -DCHANNEL_CLIPRDR=ON \
        -DCHANNEL_DISP=ON \
        -DCHANNEL_DRDYNVC=ON \
        -DCHANNEL_DRIVE=OFF \
        -DCHANNEL_ECHO=OFF \
        -DCHANNEL_ENCOMSP=OFF \
        -DCHANNEL_GEOMETRY=OFF \
        -DCHANNEL_LOCATION=OFF \
        -DCHANNEL_PARALLEL=OFF \
        -DCHANNEL_PRINTER=OFF \
        -DCHANNEL_RAIL=OFF \
        -DCHANNEL_RDPDR=OFF \
        -DCHANNEL_RDPEAR=OFF \
        -DCHANNEL_RDPECAM=OFF \
        -DCHANNEL_RDPEI=OFF \
        -DCHANNEL_RDPEMSC=OFF \
        -DCHANNEL_RDPEWA=OFF \
        -DCHANNEL_RDPGFX=ON \
        -DCHANNEL_RDPSND=OFF \
        -DCHANNEL_REMDESK=OFF \
        -DCHANNEL_SERIAL=OFF \
        -DCHANNEL_SMARTCARD=OFF \
        -DCHANNEL_SSHAGENT=OFF \
        -DCHANNEL_TELEMETRY=OFF \
        -DCHANNEL_TSMF=OFF \
        -DCHANNEL_URBDRC=OFF \
        -DCHANNEL_VIDEO=OFF

    cmake --build "$build_dir" --parallel "$(sysctl -n hw.logicalcpu)"
    cmake --install "$build_dir"

    local archive_inputs=(
        "$install_dir/lib/libfreerdp-client3.a"
        "$install_dir/lib/libfreerdp3.a"
        "$install_dir/lib/libwinpr3.a"
        "$openssl_dir/lib/libssl.a"
        "$openssl_dir/lib/libcrypto.a"
    )

    # The client archive already contains the statically selected DVC channel
    # objects. Adding the installed object-library copies a second time creates
    # duplicate disp/drdynvc/rdpgfx symbols under -all_load.
    libtool -static -o "$combined_archive" "${archive_inputs[@]}"
    ranlib "$combined_archive"

    cp -R "$install_dir/include/freerdp3/freerdp" "$headers_dir/freerdp"
    cp -R "$install_dir/include/winpr3/winpr" "$headers_dir/winpr"
    cp -R "$openssl_dir/include/openssl" "$headers_dir/openssl"
}

for arch in $ARCHITECTURES; do
    build_openssl "$arch"
    build_freerdp "$arch"
done

if [[ "$ARCHITECTURES" != "arm64 x86_64" ]]; then
    echo "JTFreeRDP.xcframework requires the ordered Universal 2 architecture set: arm64 x86_64" >&2
    exit 1
fi

# XCFrameworks represent a platform/variant once. Build one Universal 2 archive
# instead of trying to add two equivalent macOS library definitions.
UNIVERSAL_ARCHIVE="$BUILD_ROOT/libJTFreeRDP-universal.a"
UNIVERSAL_HEADERS="$BUILD_ROOT/headers-universal"
lipo -create \
    "$BUILD_ROOT/libJTFreeRDP-arm64.a" \
    "$BUILD_ROOT/libJTFreeRDP-x86_64.a" \
    -output "$UNIVERSAL_ARCHIVE"

for arch in $ARCHITECTURES; do
    if ! nm -arch "$arch" -gU "$UNIVERSAL_ARCHIVE" 2>/dev/null |
        rg ' T _cliprdr_VirtualChannelEntryEx$' >/dev/null; then
        echo "Universal FreeRDP archive is missing cliprdr for $arch" >&2
        exit 1
    fi
done

rm -rf "$UNIVERSAL_HEADERS"
cp -R "$BUILD_ROOT/headers-arm64" "$UNIVERSAL_HEADERS"

# Generated build-config headers otherwise disclose the local build directory
# and differ between slices. These optional lookup paths are intentionally
# empty because the product statically links every required component.
perl -pi -e 's|^#define FREERDP_DATA_PATH .*|#define FREERDP_DATA_PATH ""|' \
    "$UNIVERSAL_HEADERS/freerdp/build-config.h"
perl -pi -e 's|^#define FREERDP_INSTALL_PREFIX .*|#define FREERDP_INSTALL_PREFIX ""|' \
    "$UNIVERSAL_HEADERS/freerdp/build-config.h"
perl -pi -e 's|^#define WINPR_INSTALL_PREFIX .*|#define WINPR_INSTALL_PREFIX ""|' \
    "$UNIVERSAL_HEADERS/winpr/build-config.h"
perl -pi -e 's|^#define WINPR_INSTALL_SYSCONFDIR .*|#define WINPR_INSTALL_SYSCONFDIR ""|' \
    "$UNIVERSAL_HEADERS/winpr/build-config.h"

rm -rf "$OUTPUT_XCFRAMEWORK"
xcodebuild -create-xcframework \
    -library "$UNIVERSAL_ARCHIVE" \
    -headers "$UNIVERSAL_HEADERS" \
    -output "$OUTPUT_XCFRAMEWORK"

mkdir -p "$OUTPUT_DIR/Licenses"
cp "$BUILD_ROOT/freerdp-source-arm64/LICENSE" "$OUTPUT_DIR/Licenses/FreeRDP-Apache-2.0.txt"
cp \
    "$BUILD_ROOT/freerdp-source-arm64/winpr/libwinpr/sysinfo/cpufeatures/NOTICE" \
    "$OUTPUT_DIR/Licenses/FreeRDP-cpufeatures-NOTICE.txt"
cp "$BUILD_ROOT/openssl-source-arm64/LICENSE.txt" "$OUTPUT_DIR/Licenses/OpenSSL-Apache-2.0.txt"

printf '%s\n' \
    '{' \
    '  "bomFormat": "CycloneDX",' \
    '  "specVersion": "1.6",' \
    '  "version": 1,' \
    '  "components": [' \
    "    {\"type\": \"library\", \"name\": \"FreeRDP\", \"version\": \"$FREERDP_VERSION\", \"licenses\": [{\"license\": {\"id\": \"Apache-2.0\"}}], \"hashes\": [{\"alg\": \"SHA-256\", \"content\": \"$FREERDP_SHA256\"}]}," \
    "    {\"type\": \"library\", \"name\": \"OpenSSL\", \"version\": \"$OPENSSL_VERSION\", \"licenses\": [{\"license\": {\"id\": \"Apache-2.0\"}}], \"hashes\": [{\"alg\": \"SHA-256\", \"content\": \"$OPENSSL_SHA256\"}]}" \
    '  ]' \
    '}' \
    > "$OUTPUT_DIR/sbom.cdx.json"

echo "Built $OUTPUT_XCFRAMEWORK"
