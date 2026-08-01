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
    VaultSquire.xcodeproj/xcshareddata/xcschemes/VaultSquire-Performance.xcscheme
    VaultSquire.xcodeproj/xcshareddata/xcschemes/VaultSquire-SandboxProbe.xcscheme
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

# `git diff --check` inspects unstaged changes only, so on a clean CI checkout it can
# never fail. These checks read the committed tree instead. Markdown is exempt from
# the trailing-whitespace rule to match `.editorconfig`.
trailing_whitespace="$(git grep -nI -E '[ '$'\t'']+$' -- . ':(exclude)*.md' || true)"
if [[ -n "$trailing_whitespace" ]]; then
    printf 'Tracked files contain trailing whitespace:\n%s\n' "$trailing_whitespace" >&2
    exit 1
fi

carriage_returns="$(git grep -lI --fixed-strings -- $'\r' -- . || true)"
if [[ -n "$carriage_returns" ]]; then
    printf 'Tracked text files contain carriage returns:\n%s\n' "$carriage_returns" >&2
    exit 1
fi

missing_final_newline=""
while IFS= read -r file; do
    [[ -s "$file" ]] || continue
    if [[ -n "$(tail -c 1 "$file")" ]]; then
        missing_final_newline+="$file"$'\n'
    fi
done < <({ git ls-files -- . ':(exclude)*.png' ':(exclude)*.icns' ':(exclude)*.pdf' || true; })

if [[ -n "$missing_final_newline" ]]; then
    printf 'Tracked text files lack a final newline:\n%s\n' "$missing_final_newline" >&2
    exit 1
fi

git diff --check
