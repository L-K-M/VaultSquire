#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUESTED_CONFIGURATION="${1:-Release}"
# Each configuration gets its own product tree. DirectProbe and SandboxProbe share a
# build configuration and bundle identifier, so a shared path would leave one signed
# artifact silently overwriting the other.
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData/${1:-Release}}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.3.app/Contents/Developer}"

case "$REQUESTED_CONFIGURATION" in
    Release)
        SCHEME="VaultSquire"
        BUILD_CONFIGURATION="Release"
        ENTITLEMENTS="$ROOT/VaultSquire/Resources/VaultSquire.entitlements"
        ;;
    DirectProbe)
        SCHEME="VaultSquire-SandboxProbe"
        BUILD_CONFIGURATION="SandboxProbe"
        ENTITLEMENTS="$ROOT/VaultSquire/Resources/VaultSquire.entitlements"
        ;;
    SandboxProbe)
        SCHEME="VaultSquire-SandboxProbe"
        BUILD_CONFIGURATION="SandboxProbe"
        ENTITLEMENTS="$ROOT/VaultSquire/Resources/VaultSquireSandbox.entitlements"
        ;;
    *)
        printf 'Usage: %s [Release|DirectProbe|SandboxProbe]\n' "$0" >&2
        exit 2
        ;;
esac

"$ROOT/scripts/verify-toolchain.sh"

xcodebuild \
    -project "$ROOT/VaultSquire.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$BUILD_CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    clean build

app_path="$DERIVED_DATA_PATH/Build/Products/$BUILD_CONFIGURATION/VaultSquire.app"
codesign \
    --force \
    --sign - \
    --options runtime \
    --timestamp=none \
    --entitlements "$ENTITLEMENTS" \
    "$app_path"

"$ROOT/scripts/verify-product.sh" "$app_path" "$REQUESTED_CONFIGURATION"

mkdir -p "$ROOT/dist"
archive_path="$ROOT/dist/VaultSquire-$REQUESTED_CONFIGURATION-arm64.zip"
temporary_archive="$archive_path.$$.tmp"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$temporary_archive"
mv -f "$temporary_archive" "$archive_path"
shasum -a 256 "$archive_path"
