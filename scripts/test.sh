#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.3.app/Contents/Developer}"

"$ROOT/scripts/verify-toolchain.sh"

mkdir -p "$DERIVED_DATA_PATH/TestResults"
result_bundle="$DERIVED_DATA_PATH/TestResults/VaultSquire-$(date +%Y%m%d%H%M%S)-$$.xcresult"

xcodebuild test \
    -project "$ROOT/VaultSquire.xcodeproj" \
    -scheme VaultSquire \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$result_bundle" \
    -skip-testing:VaultSquireUITests/VaultSquireLaunchPerformanceTests \
    -skip-testing:VaultSquireUITests/VaultSquireQuickSearchPerformanceTests \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO

printf 'Test result bundle: %s\n' "$result_bundle"
