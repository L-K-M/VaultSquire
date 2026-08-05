#!/usr/bin/env bash
# Cut a VaultSquire release only after the tracked release gate is enabled. The
# script verifies the reviewed version/build and creates a signed vX.Y.Z tag. A
# pushed tag triggers signed-only draft-prerelease automation.
#
# Usage: scripts/release.sh X.Y.Z [--push]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SEMVER_RE='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'

if [[ "${1:-}" == "--check" ]]; then
    [[ "$#" -eq 1 ]] || { printf 'Usage: %s --check\n' "$0" >&2; exit 2; }
    scripts/version.sh --check
    scripts/check-release-eligibility.sh --status
    exit 0
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    printf 'Usage: %s X.Y.Z [--push]\n' "$0"
    exit 0
fi

version=""
push=false
for argument in "$@"; do
    case "$argument" in
        --push) push=true ;;
        -*) printf 'Unknown argument: %s\n' "$argument" >&2; exit 2 ;;
        *)
            [[ -z "$version" ]] || { printf 'Version given twice.\n' >&2; exit 2; }
            version="$argument"
            ;;
    esac
done
[[ "$version" =~ $SEMVER_RE ]] || { printf 'Usage: %s X.Y.Z [--push]\n' "$0" >&2; exit 2; }

build="$(scripts/version.sh --build)"
scripts/check-release-eligibility.sh --version "$version" --build "$build"
[[ "$version" == "$(scripts/version.sh --marketing)" ]] || { printf 'Requested version does not match the reviewed project version.\n' >&2; exit 1; }
[[ "$(uname -s)" == "Darwin" ]] || { printf 'Releases must be cut on macOS.\n' >&2; exit 2; }
[[ "$(git branch --show-current)" == "main" ]] || { printf 'Releases must be cut from main.\n' >&2; exit 1; }
scripts/verify-toolchain.sh
scripts/check-release-hosting.sh
[[ -z "$(git status --porcelain)" ]] || { printf 'Working tree must be clean.\n' >&2; exit 1; }
git fetch --force origin main 'refs/tags/v*:refs/tags/v*'
scripts/version.sh --check-history
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { printf 'Local main must exactly match origin/main.\n' >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    printf 'Local tag v%s already exists.\n' "$version" >&2
    exit 1
fi
if git ls-remote --exit-code --tags origin "refs/tags/v$version" >/dev/null 2>&1; then
    printf 'Remote tag v%s already exists.\n' "$version" >&2
    exit 1
fi
git tag -s "v$version" -m "VaultSquire $version (build $build)"
printf 'Created signed tag v%s for build %s.\n' "$version" "$build"

if $push; then
    git push origin "refs/tags/v$version"
    printf 'Pushed v%s. CI will re-prove, sign, notarize, inspect, attest, and create a draft prerelease.\n' "$version"
else
    printf 'Tag not pushed. Push with: git push origin refs/tags/v%s\n' "$version"
fi
