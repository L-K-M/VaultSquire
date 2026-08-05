#!/usr/bin/env bash
# Build and install a development-signed Release app. The Apple Developer account
# must own ch.lkmc.VaultSquire and group.ch.lkmc.VaultSquire.
#
# Usage: DEVELOPMENT_TEAM=XXXXXXXXXX scripts/install-local.sh [--run]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData/DevelopmentInstall}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/VaultSquire.app}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
RUN=false
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.3.app/Contents/Developer}"

if [[ "${1:-}" == "--run" ]]; then
    RUN=true
elif [[ "$#" -ne 0 ]]; then
    printf 'Usage: DEVELOPMENT_TEAM=XXXXXXXXXX %s [--run]\n' "$0" >&2
    exit 2
fi

[[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || {
    printf 'DEVELOPMENT_TEAM must be the ten-character Apple Developer Team ID.\n' >&2
    exit 2
}
[[ "$(uname -s)" == "Darwin" ]] || { printf 'Local installation requires macOS.\n' >&2; exit 2; }
[[ "$INSTALL_PATH" == "/Applications/VaultSquire.app" ]] || {
    printf 'INSTALL_PATH is fixed to /Applications/VaultSquire.app.\n' >&2
    exit 2
}

"$ROOT/scripts/verify-toolchain.sh"
xcodebuild \
    -project "$ROOT/VaultSquire.xcodeproj" \
    -scheme VaultSquire \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY='Apple Development' \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    clean build

product="$DERIVED_DATA_PATH/Build/Products/Release/VaultSquire.app"
"$ROOT/scripts/verify-signed-product.sh" "$product" "$DEVELOPMENT_TEAM" development

osascript -e 'tell application id "ch.lkmc.VaultSquire" to quit' >/dev/null 2>&1 || true
for _ in {1..20}; do
    pgrep -x VaultSquire >/dev/null 2>&1 || break
    sleep 0.25
done
if pgrep -x VaultSquire >/dev/null 2>&1; then
    printf 'VaultSquire is still running; quit it before installing.\n' >&2
    exit 1
fi

staged_install="/Applications/.VaultSquire.app.$$.new"
previous_install="/Applications/.VaultSquire.app.$$.old"
rm -rf "$staged_install"
rm -rf "$previous_install"
cleanup_install() {
    rm -rf "$staged_install"
    if [[ -e "$previous_install" && ! -e "$INSTALL_PATH" ]]; then
        mv "$previous_install" "$INSTALL_PATH" || true
    fi
}
trap cleanup_install EXIT
ditto "$product" "$staged_install"
"$ROOT/scripts/verify-signed-product.sh" "$staged_install" "$DEVELOPMENT_TEAM" development
if [[ -e "$INSTALL_PATH" ]]; then
    mv "$INSTALL_PATH" "$previous_install"
fi
if ! mv "$staged_install" "$INSTALL_PATH"; then
    [[ ! -e "$previous_install" ]] || mv "$previous_install" "$INSTALL_PATH"
    printf 'Could not install the verified application.\n' >&2
    exit 1
fi
rm -rf "$previous_install"
trap - EXIT
printf 'Installed: %s\n' "$INSTALL_PATH"

if $RUN; then
    open "$INSTALL_PATH"
else
    open -R "$INSTALL_PATH"
fi
