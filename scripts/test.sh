#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT/DerivedData}"
# The pinned Xcode version is fixed; its install path is not. Resolution and
# the version pin both live in verify-toolchain.sh.
DEVELOPER_DIR="${DEVELOPER_DIR:-$("$ROOT/scripts/verify-toolchain.sh" --print-developer-dir)}"
export DEVELOPER_DIR

"$ROOT/scripts/verify-toolchain.sh"

mkdir -p "$DERIVED_DATA_PATH/TestResults"
result_bundle="$DERIVED_DATA_PATH/TestResults/VaultSquire-$(date +%Y%m%d%H%M%S)-$$.xcresult"

# The project's automatic Apple Development signing needs a certificate and
# provisioning profile that hosted CI runners do not have. The test lane ad-hoc
# signs instead, like the product lane in build-local.sh.
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
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER=

printf 'Test result bundle: %s\n' "$result_bundle"
