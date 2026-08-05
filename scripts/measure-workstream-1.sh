#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData/Performance}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.3.app/Contents/Developer}"

"$ROOT/scripts/verify-toolchain.sh"

mkdir -p "$DERIVED_DATA_PATH/PerformanceResults"
result_bundle="$DERIVED_DATA_PATH/PerformanceResults/WorkstreamOne-$(date +%Y%m%d%H%M%S)-$$.xcresult"

# The performance scheme deliberately excludes VaultSquireTests. That target uses a
# testable import, which would force ENABLE_TESTABILITY onto the measured product and
# make these numbers something other than Release numbers.
# The project's automatic Apple Development signing needs a certificate and
# provisioning profile that hosted CI runners do not have. This lane ad-hoc
# signs instead, like the product lane in build-local.sh.
xcodebuild test \
    -project "$ROOT/VaultSquire.xcodeproj" \
    -scheme VaultSquire-Performance \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -resultBundlePath "$result_bundle" \
    -only-testing:VaultSquireUITests/VaultSquireLaunchPerformanceTests \
    -only-testing:VaultSquireUITests/VaultSquireQuickSearchPerformanceTests \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER=

printf 'Exportable hosted-run metrics (trend data only):\n'
metrics="$(xcrun xcresulttool get test-results metrics --path "$result_bundle")"
printf '%s\n' "$metrics"

if [[ -z "$(printf '%s' "$metrics" | tr -d '[:space:]' | /usr/bin/sed -e 's/^\[\]$//')" ]]; then
    printf 'WARNING: the run exported no machine-readable metrics. This lane detects\n' >&2
    printf 'crashes and hangs only; it is not evidence that any performance budget was\n' >&2
    printf 'met. Record the named-hardware p95 numbers separately.\n' >&2
fi

printf 'Performance result bundle: %s\n' "$result_bundle"
