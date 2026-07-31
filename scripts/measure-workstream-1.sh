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

metrics_directory="$DERIVED_DATA_PATH/PerformanceResults/Metrics-$(date +%Y%m%d%H%M%S)-$$"
xcrun xcresulttool export metrics \
    --path "$result_bundle" \
    --output-path "$metrics_directory"

shopt -s globstar nullglob
metric_files=("$metrics_directory"/**/*.csv)
if [[ "${#metric_files[@]}" -eq 0 ]]; then
    printf 'The performance result contained no exported metric CSV files.\n' >&2
    exit 1
fi

for metric_file in "${metric_files[@]}"; do
    printf 'Performance metrics: %s\n' "${metric_file#"$metrics_directory"/}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line"
    done <"$metric_file"
done

printf 'Performance result bundle: %s\n' "$result_bundle"
