#!/usr/bin/env bash
# Build and install a development-signed Release app. The Apple Developer account
# must own ch.lkmc.VaultSquire and group.ch.lkmc.VaultSquire. The Apple Developer
# Team ID comes from the Xcode project, which is authoritative for it exactly as
# it is for the version; DEVELOPMENT_TEAM overrides it for a contributor signing
# with a different account.
#
# Usage: [DEVELOPMENT_TEAM=XXXXXXXXXX] scripts/install-local.sh [--run|--reveal|--no-reveal]
#        scripts/install-local.sh --print-team
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/VaultSquire.xcodeproj/project.pbxproj"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData/DevelopmentInstall}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/VaultSquire.app}"
RUN=false
REVEAL=true
PRINT_TEAM=false
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.3.app/Contents/Developer}"

usage() {
    printf 'Usage: [DEVELOPMENT_TEAM=XXXXXXXXXX] %s [--run|--reveal|--no-reveal]\n' "$0" >&2
    printf '       %s --print-team\n' "$0" >&2
}

case "${1:-}" in
    "") ;;
    --run) RUN=true ;;
    --reveal) ;;
    --no-reveal) REVEAL=false ;;
    --print-team) PRINT_TEAM=true ;;
    *) usage; exit 2 ;;
esac
[[ "$#" -le 1 ]] || { usage; exit 2; }

# Read the project's own Team ID rather than demanding the operator restate it.
# `sort -u` collapses the per-configuration settings, so a project whose
# configurations disagree fails loudly instead of picking one of them.
project_teams="$(/usr/bin/sed -nE 's/^[[:space:]]*DEVELOPMENT_TEAM = "?([^";]*)"?;/\1/p' "$PROJECT" | /usr/bin/sort -u)"
project_team_count="$(printf '%s\n' "$project_teams" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    TEAM_SOURCE="the DEVELOPMENT_TEAM environment variable"
elif [[ "$project_team_count" -eq 1 ]]; then
    DEVELOPMENT_TEAM="$project_teams"
    TEAM_SOURCE="the Xcode project"
else
    printf 'The Xcode project does not record exactly one DEVELOPMENT_TEAM (found: %s).\n' \
        "${project_teams:-<none>}" >&2
    printf 'Supply the ten-character Apple Developer Team ID instead:\n' >&2
    printf '  DEVELOPMENT_TEAM=XXXXXXXXXX %s\n' "$0" >&2
    exit 2
fi

[[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || {
    printf 'The Apple Developer Team ID from %s is not ten characters of A-Z0-9: %s\n' \
        "$TEAM_SOURCE" "$DEVELOPMENT_TEAM" >&2
    exit 2
}

if $PRINT_TEAM; then
    printf '%s (from %s)\n' "$DEVELOPMENT_TEAM" "$TEAM_SOURCE"
    exit 0
fi

[[ "$(uname -s)" == "Darwin" ]] || { printf 'Local installation requires macOS.\n' >&2; exit 2; }
[[ "$INSTALL_PATH" == "/Applications/VaultSquire.app" ]] || {
    printf 'INSTALL_PATH is fixed to /Applications/VaultSquire.app.\n' >&2
    exit 2
}
printf 'Signing with Apple Developer Team %s from %s.\n' "$DEVELOPMENT_TEAM" "$TEAM_SOURCE"

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
elif $REVEAL; then
    open -R "$INSTALL_PATH"
fi
