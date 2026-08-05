#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -lt 3 || "$#" -gt 5 ]]; then
    printf 'Usage: %s APP_PATH TEAM_ID development|developer-id [VERSION BUILD]\n' "$0" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$1"
TEAM_ID="$2"
SIGNING_MODE="$3"
EXPECTED_VERSION="${4:-$("$ROOT/scripts/version.sh" --marketing)}"
EXPECTED_BUILD="${5:-$("$ROOT/scripts/version.sh" --build)}"
BINARY="$APP_PATH/Contents/MacOS/VaultSquire"
INFO="$APP_PATH/Contents/Info.plist"
PROFILE="$APP_PATH/Contents/embedded.provisionprofile"

[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { printf 'Invalid Apple Team ID.\n' >&2; exit 2; }
[[ "$SIGNING_MODE" == "development" || "$SIGNING_MODE" == "developer-id" ]] || { printf 'Invalid signing mode.\n' >&2; exit 2; }
[[ -x "$BINARY" ]] || { printf 'Application executable is missing: %s\n' "$BINARY" >&2; exit 1; }
[[ -f "$INFO" ]] || { printf 'Application Info.plist is missing.\n' >&2; exit 1; }
[[ -f "$PROFILE" ]] || { printf 'Application provisioning profile is missing.\n' >&2; exit 1; }

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
signature_details="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
printf '%s\n' "$signature_details" | /usr/bin/grep -q '^Identifier=ch.lkmc.VaultSquire$' || { printf 'Unexpected signed bundle identifier.\n' >&2; exit 1; }
printf '%s\n' "$signature_details" | /usr/bin/grep -q "^TeamIdentifier=$TEAM_ID$" || { printf 'Unexpected signed Team ID.\n' >&2; exit 1; }
printf '%s\n' "$signature_details" | /usr/bin/grep -qE '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime[,)]' || { printf 'Hardened Runtime flag is missing.\n' >&2; exit 1; }
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    printf '%s\n' "$signature_details" | /usr/bin/grep -q '^Authority=Developer ID Application:' || { printf 'Developer ID Application authority is missing.\n' >&2; exit 1; }
    printf '%s\n' "$signature_details" | /usr/bin/grep -q '^Timestamp=' || { printf 'Secure signing timestamp is missing.\n' >&2; exit 1; }
else
    printf '%s\n' "$signature_details" | /usr/bin/grep -q '^Authority=Apple Development:' || { printf 'Apple Development authority is missing.\n' >&2; exit 1; }
fi
codesign --verify --strict --verbose=2 \
    --test-requirement "=anchor apple generic and identifier \"ch.lkmc.VaultSquire\" and certificate leaf[subject.OU] = \"$TEAM_ID\"" \
    "$APP_PATH"

[[ "$(lipo -archs "$BINARY")" == "arm64" ]] || { printf 'Signed product is not exactly arm64.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "ch.lkmc.VaultSquire" ]] || { printf 'Unexpected bundle identifier.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" == "$EXPECTED_VERSION" ]] || { printf 'Unexpected marketing version.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" == "$EXPECTED_BUILD" ]] || { printf 'Unexpected build number.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")" == "14.0" ]] || { printf 'Unexpected minimum macOS version.\n' >&2; exit 1; }

actual_entitlements="$(mktemp)"
profile_plist="$(mktemp)"
trap 'rm -f "$actual_entitlements" "$profile_plist"' EXIT
codesign --display --entitlements :- "$APP_PATH" >"$actual_entitlements" 2>/dev/null
security cms -D -i "$PROFILE" >"$profile_plist"
plutil -lint "$actual_entitlements" "$profile_plist" >/dev/null

actual_keys="$(/usr/bin/grep -o '<key>[^<]*</key>' "$actual_entitlements" | /usr/bin/sed -e 's/<key>//' -e 's#</key>##' | /usr/bin/sort)"
allowed_keys=$'com.apple.application-identifier\ncom.apple.developer.team-identifier\ncom.apple.security.application-groups'
if printf '%s\n' "$actual_keys" | /usr/bin/grep -q '^keychain-access-groups$'; then
    allowed_keys+=$'\nkeychain-access-groups'
fi
if printf '%s\n' "$actual_keys" | /usr/bin/grep -q '^com.apple.security.get-task-allow$'; then
    if [[ "$SIGNING_MODE" != "development" || "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$actual_entitlements")" != "true" ]]; then
        printf 'Debugger attachment entitlement is prohibited for this signing mode.\n' >&2
        exit 1
    fi
    allowed_keys+=$'\ncom.apple.security.get-task-allow'
fi
if ! diff -u <(printf '%s\n' "$allowed_keys" | /usr/bin/sort) <(printf '%s\n' "$actual_keys"); then
    printf 'Signed entitlement keys do not match the provisioning-aware allowlist.\n' >&2
    exit 1
fi

[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$actual_entitlements")" == "$TEAM_ID.ch.lkmc.VaultSquire" ]] || { printf 'Unexpected application identifier entitlement.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$actual_entitlements")" == "$TEAM_ID" ]] || { printf 'Unexpected team entitlement.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$actual_entitlements")" == "group.ch.lkmc.VaultSquire" ]] || { printf 'Unexpected App Group entitlement.\n' >&2; exit 1; }
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:1' "$actual_entitlements" >/dev/null 2>&1; then
    printf 'Unexpected additional App Group entitlement.\n' >&2
    exit 1
fi
if printf '%s\n' "$actual_keys" | /usr/bin/grep -q '^keychain-access-groups$'; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$actual_entitlements")" == "$TEAM_ID.ch.lkmc.VaultSquire" ]] || { printf 'Unexpected Keychain access group.\n' >&2; exit 1; }
    if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:1' "$actual_entitlements" >/dev/null 2>&1; then
        printf 'Unexpected additional Keychain access group.\n' >&2
        exit 1
    fi
fi

[[ "$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")" == "$TEAM_ID" ]] || { printf 'Provisioning profile Team ID mismatch.\n' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Platform:0' "$profile_plist")" == "OSX" ]] || { printf 'Provisioning profile is not for macOS.\n' >&2; exit 1; }
profile_application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist")"
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    [[ "$profile_application_identifier" == "$TEAM_ID.ch.lkmc.VaultSquire" ]] || { printf 'Provisioning profile application identifier mismatch.\n' >&2; exit 1; }
else
    [[ "$profile_application_identifier" == "$TEAM_ID.ch.lkmc.VaultSquire" || "$profile_application_identifier" == "$TEAM_ID.*" ]] || { printf 'Development profile application identifier mismatch.\n' >&2; exit 1; }
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups:0' "$profile_plist")" == "group.ch.lkmc.VaultSquire" ]] || { printf 'Provisioning profile App Group mismatch.\n' >&2; exit 1; }
if /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups:1' "$profile_plist" >/dev/null 2>&1; then
    printf 'Provisioning profile contains an additional App Group.\n' >&2
    exit 1
fi
profile_expiration="$(plutil -extract ExpirationDate raw -o - "$profile_plist")"
[[ "$profile_expiration" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || { printf 'Provisioning profile is expired.\n' >&2; exit 1; }
if [[ "$SIGNING_MODE" == "developer-id" ]] \
    && /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.get-task-allow' "$profile_plist" 2>/dev/null | /usr/bin/grep -q '^true$'; then
    printf 'Provisioning profile enables debugger attachment.\n' >&2
    exit 1
fi
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$profile_plist")" == "true" ]] || { printf 'Provisioning profile is not for Developer ID distribution.\n' >&2; exit 1; }
    if /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$profile_plist" >/dev/null 2>&1; then
        printf 'Developer ID profile unexpectedly limits devices.\n' >&2
        exit 1
    fi
fi

leaf_certificate="$(mktemp)"
profile_certificate="$(mktemp)"
certificates_directory="$(mktemp -d)"
trap 'rm -f "$actual_entitlements" "$profile_plist" "$leaf_certificate" "$profile_certificate"; rm -rf "$certificates_directory"' EXIT
codesign --display --extract-certificates "$certificates_directory/cert" "$APP_PATH" >/dev/null 2>&1
cp "$certificates_directory/cert0" "$leaf_certificate"
certificate_count="$(plutil -extract DeveloperCertificates raw -o - "$profile_plist")"
certificate_match=false
for ((index = 0; index < certificate_count; index++)); do
    plutil -extract "DeveloperCertificates.$index" raw -o - "$profile_plist" \
        | base64 --decode > "$profile_certificate"
    if cmp -s "$leaf_certificate" "$profile_certificate"; then
        certificate_match=true
        break
    fi
done
$certificate_match || { printf 'Provisioning profile does not contain the signing certificate.\n' >&2; exit 1; }

requirement="$(codesign --display --requirements :- "$APP_PATH" 2>&1)"
[[ "$requirement" == *'identifier "ch.lkmc.VaultSquire"'* ]] || { printf 'Unexpected designated requirement.\n' >&2; exit 1; }

unexpected_links="$(otool -L "$BINARY" | /usr/bin/sed -n '2,$s/^[[:space:]]*\([^[:space:]]*\).*/\1/p' | /usr/bin/grep -Ev '^(/System/Library/|/usr/lib/)' || true)"
[[ -z "$unexpected_links" ]] || { printf 'Unexpected non-system linked images:\n%s\n' "$unexpected_links" >&2; exit 1; }
for directory in Frameworks SharedFrameworks PlugIns Plug-ins XPCServices Helpers; do
    [[ ! -e "$APP_PATH/Contents/$directory" ]] || { printf 'Unexpected nested code directory: %s\n' "$directory" >&2; exit 1; }
done
for directory in Automator Spotlight LoginItems LaunchServices; do
    [[ ! -e "$APP_PATH/Contents/Library/$directory" ]] || { printf 'Unexpected nested code directory: Library/%s\n' "$directory" >&2; exit 1; }
done
[[ "$(/usr/bin/find "$APP_PATH/Contents/MacOS" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" -eq 1 ]] || { printf 'Unexpected additional Contents/MacOS entry.\n' >&2; exit 1; }
unexpected_executables="$(/usr/bin/find "$APP_PATH/Contents" -type f -perm -111 ! -path "$BINARY" -print)"
[[ -z "$unexpected_executables" ]] || { printf 'Unexpected executable files:\n%s\n' "$unexpected_executables" >&2; exit 1; }
unexpected_macho=""
while IFS= read -r -d '' file; do
    if [[ "$file" != "$BINARY" ]] && /usr/bin/file -b "$file" | /usr/bin/grep -q 'Mach-O'; then
        unexpected_macho+="$file"$'\n'
    fi
done < <(/usr/bin/find "$APP_PATH/Contents" -type f -print0)
[[ -z "$unexpected_macho" ]] || { printf 'Unexpected Mach-O files:\n%s' "$unexpected_macho" >&2; exit 1; }

printf 'Verified %s signed product at %s\n' "$SIGNING_MODE" "$APP_PATH"
