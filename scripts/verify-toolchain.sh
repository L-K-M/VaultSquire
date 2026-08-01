#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'VaultSquire product commands require macOS.\n' >&2
    exit 2
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    printf 'Workstream 1 requires a native Apple Silicon host.\n' >&2
    exit 2
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.3.app/Contents/Developer}"
if [[ ! -d "$DEVELOPER_DIR" ]]; then
    printf 'Expected Xcode developer directory is unavailable: %s\n' "$DEVELOPER_DIR" >&2
    exit 2
fi

xcode_version="$(xcodebuild -version)"
if [[ "$xcode_version" != Xcode\ 26.3$'\n'* ]]; then
    printf 'Expected Xcode 26.3, found:\n%s\n' "$xcode_version" >&2
    exit 2
fi

printf '%s\n' "$xcode_version"
xcrun swiftc --version
printf 'macOS SDK version: %s\n' "$(xcrun --sdk macosx --show-sdk-version)"
printf 'macOS SDK build: %s\n' "$(xcrun --sdk macosx --show-sdk-build-version)"
sw_vers
printf 'Host architecture: %s\n' "$(uname -m)"
