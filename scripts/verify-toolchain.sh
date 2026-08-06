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

# Survey every distinct candidate once, emitting "path<TAB>version-or-status" in
# search order. The candidate list overlaps by design — the xcode-select
# selection is usually /Applications/Xcode.app, which the glob finds again — so
# deduplicating here keeps one real Xcode from being reported as three.
developer_dir_survey() {
    local candidate previous seen
    local considered=""
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        seen=false
        while IFS= read -r previous; do
            [[ "$previous" == "$candidate" ]] && { seen=true; break; }
        done <<<"$considered"
        $seen && continue
        considered="$considered$candidate"$'\n'
        if [[ -d "$candidate" ]]; then
            printf '%s\t%s\n' "$candidate" "$(developer_dir_version "$candidate" || echo 'no xcodebuild')"
        else
            printf '%s\tabsent\n' "$candidate"
        fi
    done < <(candidate_developer_dirs)
    return 0
}

resolve_developer_dir() {
    local survey path status found_an_xcode=false
    survey="$(developer_dir_survey)"

    while IFS=$'\t' read -r path status; do
        [[ -n "$path" ]] || continue
        if [[ "$status" == "Xcode $REQUIRED_XCODE_VERSION" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
        [[ "$status" == Xcode\ * ]] && found_an_xcode=true
    done <<<"$survey"

    printf 'No Xcode %s developer directory was found. Searched:\n' "$REQUIRED_XCODE_VERSION" >&2
    while IFS=$'\t' read -r path status; do
        [[ -n "$path" ]] || continue
        printf '  %s (%s)\n' "$path" "$status" >&2
    done <<<"$survey"

    if $found_an_xcode; then
        # DEVELOPER_DIR is not an escape hatch here: the version check below runs
        # against whatever it selects, so pointing at the wrong version still
        # fails. Say so instead of suggesting a remedy that cannot work.
        printf 'Xcode is installed but not at the pinned version. %s is pinned exactly\n' "$REQUIRED_XCODE_VERSION" >&2
        printf '(WORKSTREAM_1.md), and DEVELOPER_DIR does not bypass that check.\n' >&2
        printf 'Install Xcode %s alongside the one you have, from\n' "$REQUIRED_XCODE_VERSION" >&2
        printf 'https://developer.apple.com/download/all/?q=xcode, as\n' >&2
        printf '  /Applications/Xcode_%s.app\n' "$REQUIRED_XCODE_VERSION" >&2
        printf 'which is searched first and is the name the hosted runner uses. Keep the\n' >&2
        printf 'existing Xcode: this never changes the xcode-select selection. Changing the\n' >&2
        printf 'pin instead is a reviewed change across this script, the workflows, and\n' >&2
        printf 'WORKSTREAM_1.md, and it also has to fit the runner image.\n' >&2
    else
        printf 'Install Xcode %s, or point at it explicitly:\n' "$REQUIRED_XCODE_VERSION" >&2
        printf '  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer %s\n' "$0" >&2
    fi
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
