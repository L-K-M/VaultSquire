#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData/Performance}"
# The pinned Xcode version is fixed; its install path is not. Resolution and
# the version pin both live in verify-toolchain.sh.
DEVELOPER_DIR="${DEVELOPER_DIR:-$("$ROOT/scripts/verify-toolchain.sh" --print-developer-dir)}"
export DEVELOPER_DIR

"$ROOT/scripts/verify-toolchain.sh"

mkdir -p "$DERIVED_DATA_PATH/PerformanceResults"

# The performance scheme deliberately excludes VaultSquireTests. That target uses a
# testable import, which would force ENABLE_TESTABILITY onto the measured product and
# make these numbers something other than Release numbers.
# The project's automatic Apple Development signing needs a certificate and
# provisioning profile that hosted CI runners do not have. This lane ad-hoc
# signs instead, like the product lane in build-local.sh.
run_measurement() {
    local attempt="$1"
    result_bundle="$DERIVED_DATA_PATH/PerformanceResults/WorkstreamOne-$(date +%Y%m%d%H%M%S)-$$-a$attempt.xcresult"
    local log="$DERIVED_DATA_PATH/PerformanceResults/attempt-$attempt.log"
    if xcodebuild test \
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
        PROVISIONING_PROFILE_SPECIFIER= \
        2>&1 | tee "$log"; then
        return 0
    fi
    # Hosted runners intermittently fail to attach the accessibility bus to a
    # freshly launched app ("Application ... has not loaded accessibility"),
    # timing out both measurements while the functional lane's UI tests pass on
    # the same binary minutes earlier. That exact signature — and only it —
    # earns one retry; a genuine perf failure or crash still fails the lane.
    if grep -q "has not loaded accessibility" "$log"; then
        return 42
    fi
    return 1
}

status=0
run_measurement 1 || status=$?
if [[ "$status" -eq 42 ]]; then
    printf 'The runner never attached accessibility to the app; retrying the\n' >&2
    printf 'measurement once on this booted machine.\n' >&2
    status=0
    run_measurement 2 || status=$?
fi
if [[ "$status" -ne 0 ]]; then
    exit "$status"
fi

printf 'Exportable hosted-run metrics (trend data only):\n'
metrics="$(xcrun xcresulttool get test-results metrics --path "$result_bundle")"
printf '%s\n' "$metrics"

if [[ -z "$(printf '%s' "$metrics" | tr -d '[:space:]' | /usr/bin/sed -e 's/^\[\]$//')" ]]; then
    printf 'WARNING: the run exported no machine-readable metrics. This lane detects\n' >&2
    printf 'crashes and hangs only; it is not evidence that any performance budget was\n' >&2
    printf 'met. Record the named-hardware p95 numbers separately.\n' >&2
fi

printf 'Performance result bundle: %s\n' "$result_bundle"
