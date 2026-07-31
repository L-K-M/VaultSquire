#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    printf 'Usage: %s APP_PATH CONFIGURATION\n' "$0" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$1"
CONFIGURATION="$2"
BINARY="$APP_PATH/Contents/MacOS/VaultSquire"

case "$CONFIGURATION" in
    Release | DirectProbe)
        EXPECTED_ENTITLEMENTS="$ROOT/VaultSquire/Resources/VaultSquire.entitlements"
        ;;
    SandboxProbe)
        EXPECTED_ENTITLEMENTS="$ROOT/VaultSquire/Resources/VaultSquireSandbox.entitlements"
        ;;
    *)
        printf 'Unsupported product verification configuration: %s\n' "$CONFIGURATION" >&2
        exit 2
        ;;
esac

if [[ ! -x "$BINARY" ]]; then
    printf 'Built application executable is missing: %s\n' "$BINARY" >&2
    exit 1
fi

codesign --verify --strict --verbose=2 "$APP_PATH"

signature_details="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
if [[ "$signature_details" != *runtime* ]]; then
    printf 'Hardened Runtime flag is missing from the application signature.\n' >&2
    exit 1
fi

architectures="$(lipo -archs "$BINARY")"
if [[ "$architectures" != "arm64" ]]; then
    printf 'Expected exactly arm64, found: %s\n' "$architectures" >&2
    exit 1
fi

actual_entitlements="$(mktemp)"
trap 'rm -f "$actual_entitlements"' EXIT
codesign --display --entitlements :- "$APP_PATH" >"$actual_entitlements" 2>/dev/null
plutil -lint "$actual_entitlements" >/dev/null

plist_keys() {
    /usr/bin/grep -o '<key>[^<]*</key>' "$1" \
        | /usr/bin/sed -e 's/<key>//' -e 's#</key>##' \
        | /usr/bin/sort
}

if ! diff -u <(plist_keys "$EXPECTED_ENTITLEMENTS") <(plist_keys "$actual_entitlements"); then
    printf 'Signed entitlement keys do not match the reviewed allowlist.\n' >&2
    exit 1
fi

app_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$actual_entitlements")"
if [[ "$app_group" != "group.ch.lkmc.VaultSquire" ]]; then
    printf 'Unexpected application group entitlement.\n' >&2
    exit 1
fi

prohibited_entitlements=(
    com.apple.security.cs.get-task-allow
    com.apple.security.cs.allow-dyld-environment-variables
    com.apple.security.cs.disable-library-validation
    com.apple.security.cs.disable-executable-page-protection
    com.apple.security.cs.allow-unsigned-executable-memory
    com.apple.security.cs.allow-jit
    com.apple.security.automation.apple-events
)

for entitlement in "${prohibited_entitlements[@]}"; do
    if /usr/libexec/PlistBuddy -c "Print :$entitlement" "$actual_entitlements" >/dev/null 2>&1; then
        printf 'Prohibited entitlement present: %s\n' "$entitlement" >&2
        exit 1
    fi
done

if [[ "$CONFIGURATION" == "SandboxProbe" ]]; then
    for entitlement in \
        com.apple.security.app-sandbox \
        com.apple.security.files.user-selected.read-only \
        com.apple.security.network.client; do
        if [[ "$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$actual_entitlements")" != "true" ]]; then
            printf 'Required sandbox probe entitlement is absent: %s\n' "$entitlement" >&2
            exit 1
        fi
    done
fi

unexpected_links="$(otool -L "$BINARY" \
    | /usr/bin/sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    | /usr/bin/grep -Ev '^(/System/Library/|/usr/lib/)' || true)"
if [[ -n "$unexpected_links" ]]; then
    printf 'Unexpected non-system linked images:\n%s\n' "$unexpected_links" >&2
    exit 1
fi

printf 'Verified %s product at %s\n' "$CONFIGURATION" "$APP_PATH"
