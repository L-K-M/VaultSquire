#!/usr/bin/env bash
# Build a verified VaultSquire product. Release is the default; probe variants
# preserve their reviewed entitlement contracts. --install uses Apple Development
# signing and a real App Group provisioning profile instead of the ad-hoc CI path.
#
# Usage: scripts/build.sh [Release|DirectProbe|SandboxProbe] [--clean] [--run] [--install] [--check] [--no-reveal]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="Release"
RUN=false
INSTALL=false
CHECK=false
REVEAL=true

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        Release|DirectProbe|SandboxProbe) CONFIGURATION="$1" ;;
        --clean) ;; # build-local.sh always starts from a clean configuration tree.
        --run) RUN=true ;;
        --install) INSTALL=true ;;
        --check) CHECK=true ;;
        --no-reveal) REVEAL=false ;;
        -h|--help)
            /usr/bin/sed -n '2,/^set -euo pipefail/{ /^#/s/^# \{0,1\}//p; }' "$0"
            exit 0
            ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

if $INSTALL && [[ "$CONFIGURATION" != "Release" ]]; then
    printf 'Only the Release product can be installed.\n' >&2
    exit 2
fi

product_configuration="$CONFIGURATION"
[[ "$CONFIGURATION" == "DirectProbe" || "$CONFIGURATION" == "SandboxProbe" ]] && product_configuration="SandboxProbe"
derived_data="${DERIVED_DATA_PATH:-$ROOT/DerivedData/$CONFIGURATION}"
product="$derived_data/Build/Products/$product_configuration/VaultSquire.app"

if $CHECK; then
    "$ROOT/scripts/version.sh" --check
    "$ROOT/scripts/check-release-eligibility.sh" --status
    printf 'configuration: %s\n' "$CONFIGURATION"
    printf 'product:       %s\n' "$product"
    $INSTALL && printf 'install:       /Applications/VaultSquire.app (Apple Development signing required)\n'
    exit 0
fi

if $INSTALL; then
    if $RUN; then
        "$ROOT/scripts/install-local.sh" --run
    else
        "$ROOT/scripts/install-local.sh"
    fi
    exit 0
fi

"$ROOT/scripts/build-local.sh" "$CONFIGURATION"

if $RUN; then
    open "$product"
elif $REVEAL; then
    open -R "$product"
else
    printf 'Built product: %s\n' "$product"
fi
