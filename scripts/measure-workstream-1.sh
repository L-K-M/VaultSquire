#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.3.app/Contents/Developer}"

"$ROOT/scripts/verify-toolchain.sh"

mkdir -p "$DERIVED_DATA_PATH/PerformanceResults"
result_bundle="$DERIVED_DATA_PATH/PerformanceResults/WorkstreamOne-$(date +%Y%m%d%H%M%S)-$$.xcresult"

xcodebuild test \
    -project "$ROOT/VaultSquire.xcodeproj" \
    -scheme VaultSquire \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$result_bundle" \
    -only-testing:VaultSquireTests/WorkstreamOnePerformanceTests \
    -only-testing:VaultSquireUITests/VaultSquireLaunchPerformanceTests \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    ENABLE_TESTABILITY=YES

printf 'Exportable hosted-run metrics (trend data only):\n'
xcrun xcresulttool get test-results metrics --path "$result_bundle"
printf 'Performance result bundle: %s\n' "$result_bundle"
