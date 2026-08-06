#!/usr/bin/env bash
# Verify the pinned toolchain and print it as build evidence.
#
# The Xcode version is a hard pin (WORKSTREAM_1.md); its install path is not.
# `/Applications/Xcode_26.3.app` is the GitHub-hosted runner's naming
# convention, so hardcoding it as the only default made every product command
# fail on an ordinary Mac, where Xcode lives at `/Applications/Xcode.app`.
# DEVELOPER_DIR still wins when set, which is how CI pins the runner's copy.
#
# Usage: scripts/verify-toolchain.sh [--print-developer-dir]
set -euo pipefail

REQUIRED_XCODE_VERSION="26.3"
PRINT_DEVELOPER_DIR=false

case "${1:-}" in
    "") ;;
    --print-developer-dir) PRINT_DEVELOPER_DIR=true ;;
    *) printf 'Usage: %s [--print-developer-dir]\n' "$0" >&2; exit 2 ;;
esac
[[ "$#" -le 1 ]] || { printf 'Usage: %s [--print-developer-dir]\n' "$0" >&2; exit 2; }

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'VaultSquire product commands require macOS.\n' >&2
    exit 2
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    printf 'Workstream 1 requires a native Apple Silicon host.\n' >&2
    exit 2
fi

# Ask the candidate directly rather than through the `xcodebuild` shim, so the
# answer cannot depend on the caller's own DEVELOPER_DIR or xcode-select state.
developer_dir_version() {
    [[ -x "$1/usr/bin/xcodebuild" ]] || return 1
    "$1/usr/bin/xcodebuild" -version 2>/dev/null | /usr/bin/head -n 1
}

# The hosted-runner path stays first so CI resolves exactly what it did before.
candidate_developer_dirs() {
    printf '%s\n' "/Applications/Xcode_$REQUIRED_XCODE_VERSION.app/Contents/Developer"
    local selected
    selected="$(xcode-select --print-path 2>/dev/null || true)"
    [[ -n "$selected" ]] && printf '%s\n' "$selected"
    printf '%s\n' "/Applications/Xcode.app/Contents/Developer"
    local application
    for application in /Applications/Xcode*.app; do
        [[ -d "$application" ]] && printf '%s\n' "$application/Contents/Developer"
    done
    return 0
}

resolve_developer_dir() {
    local candidate
    local considered=""
    while IFS= read -r candidate; do
        [[ -n "$candidate" && -d "$candidate" ]] || continue
        case "$considered" in
            *"|$candidate|"*) continue ;;
        esac
        considered="$considered|$candidate|"
        if [[ "$(developer_dir_version "$candidate" || true)" == "Xcode $REQUIRED_XCODE_VERSION" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(candidate_developer_dirs)

    printf 'No Xcode %s developer directory was found. Searched:\n' "$REQUIRED_XCODE_VERSION" >&2
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        if [[ -d "$candidate" ]]; then
            printf '  %s (%s)\n' "$candidate" "$(developer_dir_version "$candidate" || echo 'no xcodebuild')" >&2
        else
            printf '  %s (absent)\n' "$candidate" >&2
        fi
    done < <(candidate_developer_dirs)
    printf 'Install Xcode %s, or point at it explicitly:\n' "$REQUIRED_XCODE_VERSION" >&2
    printf '  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer %s\n' "$0" >&2
    return 2
}

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    DEVELOPER_DIR="$(resolve_developer_dir)"
fi
export DEVELOPER_DIR

if [[ ! -d "$DEVELOPER_DIR" ]]; then
    printf 'Expected Xcode developer directory is unavailable: %s\n' "$DEVELOPER_DIR" >&2
    exit 2
fi

if $PRINT_DEVELOPER_DIR; then
    printf '%s\n' "$DEVELOPER_DIR"
    exit 0
fi

xcode_version="$(xcodebuild -version)"
if [[ "$xcode_version" != Xcode\ $REQUIRED_XCODE_VERSION$'\n'* ]]; then
    printf 'Expected Xcode %s, found:\n%s\n' "$REQUIRED_XCODE_VERSION" "$xcode_version" >&2
    exit 2
fi

printf '%s\n' "$xcode_version"
printf 'Developer directory: %s\n' "$DEVELOPER_DIR"
xcrun swiftc --version
printf 'macOS SDK version: %s\n' "$(xcrun --sdk macosx --show-sdk-version)"
printf 'macOS SDK build: %s\n' "$(xcrun --sdk macosx --show-sdk-build-version)"
sw_vers
printf 'Host architecture: %s\n' "$(uname -m)"
