#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

required_files=(
    AGENTS.md
    CONTRIBUTING.md
    PRIVACY.md
    SECURITY.md
    LICENSE
    .claude/settings.json
    .github/dependabot.yml
    VaultSquire.xcodeproj/project.pbxproj
    VaultSquire.xcodeproj/xcshareddata/xcschemes/VaultSquire.xcscheme
)

for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        printf 'Missing required file: %s\n' "$file" >&2
        exit 1
    fi
done

if command -v jq >/dev/null 2>&1; then
    jq empty .claude/settings.json
elif command -v plutil >/dev/null 2>&1; then
    plutil -lint .claude/settings.json >/dev/null
else
    printf 'Neither jq nor plutil is available to validate JSON.\n' >&2
    exit 1
fi

forbidden_paths="$({ git ls-files || true; } | /usr/bin/grep -E '(^|/)(\.idea|\.vscode)(/|$)|(^|/)\.DS_Store$|workspace\.xml$|(^|/)\.env($|\.)|\.(p8|p12|mobileprovision|provisionprofile)$' || true)"
if [[ -n "$forbidden_paths" ]]; then
    printf 'Tracked local or sensitive files detected:\n%s\n' "$forbidden_paths" >&2
    exit 1
fi

private_key_markers="$(git grep -nI -E 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|AKIA[0-9A-Z]{16}' -- . ':(exclude)scripts/check-repository.sh' || true)"
if [[ -n "$private_key_markers" ]]; then
    printf 'Potential private key or cloud credential detected:\n%s\n' "$private_key_markers" >&2
    exit 1
fi

dependency_manifests="$({ git ls-files || true; } | /usr/bin/grep -E '(^|/)(Package\.swift|Package\.resolved|Podfile|Podfile\.lock|Cartfile|Cartfile\.resolved)$' || true)"
if [[ -n "$dependency_manifests" ]]; then
    printf 'Unapproved application dependency manifest detected:\n%s\n' "$dependency_manifests" >&2
    exit 1
fi

expected_icon_hash="438060d1a8740e69cb1330ee60c218e23556edcf6c4a5d6333ee21b051201eeb"
if command -v sha256sum >/dev/null 2>&1; then
    actual_icon_hash="$(sha256sum media-sources/icon.png | /usr/bin/cut -d ' ' -f 1)"
else
    actual_icon_hash="$(shasum -a 256 media-sources/icon.png | /usr/bin/cut -d ' ' -f 1)"
fi

if [[ "$actual_icon_hash" != "$expected_icon_hash" ]]; then
    printf 'Canonical icon hash mismatch.\n' >&2
    exit 1
fi

git diff --check
