#!/usr/bin/env bash
# Read, validate, or synchronize the Xcode marketing version and build number.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/VaultSquire.xcodeproj/project.pbxproj"
README="$ROOT/README.md"
SEMVER_RE='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'

marketing_versions() {
    /usr/bin/sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);/\1/p' "$PROJECT" \
        | /usr/bin/sort -u
}

build_versions() {
    /usr/bin/sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' "$PROJECT" \
        | /usr/bin/sort -u
}

read_single_value() {
    local label="$1"
    local values="$2"
    local count
    count="$(printf '%s\n' "$values" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
    if [[ "$count" -ne 1 ]]; then
        printf 'Expected one %s across product configurations, found: %s\n' \
            "$label" "${values:-<none>}" >&2
        exit 1
    fi
    printf '%s\n' "$values"
}

marketing="$(read_single_value 'MARKETING_VERSION' "$(marketing_versions)")"
build="$(read_single_value 'CURRENT_PROJECT_VERSION' "$(build_versions)")"
[[ "$marketing" =~ $SEMVER_RE ]] || { printf 'Invalid marketing version: %s\n' "$marketing" >&2; exit 1; }
[[ "$build" =~ ^[1-9][0-9]{0,8}$ ]] || { printf 'Invalid build number: %s\n' "$build" >&2; exit 1; }
[[ "$(/usr/bin/grep -c 'MARKETING_VERSION = ' "$PROJECT")" -eq 3 ]] || { printf 'Expected three MARKETING_VERSION settings.\n' >&2; exit 1; }
[[ "$(/usr/bin/grep -c 'CURRENT_PROJECT_VERSION = ' "$PROJECT")" -eq 3 ]] || { printf 'Expected three CURRENT_PROJECT_VERSION settings.\n' >&2; exit 1; }
[[ "$(/usr/bin/grep -c '<!-- version -->' "$README")" -eq 1 ]] || { printf 'Expected one README version marker.\n' >&2; exit 1; }
/usr/bin/grep -qF "<!-- version -->$marketing<!-- /version -->" "$README" || { printf 'README source version does not match the project.\n' >&2; exit 1; }

version_is_greater() {
    local candidate="$1"
    local previous="$2"
    local candidate_major candidate_minor candidate_patch
    local previous_major previous_minor previous_patch
    IFS=. read -r candidate_major candidate_minor candidate_patch <<<"$candidate"
    IFS=. read -r previous_major previous_minor previous_patch <<<"$previous"
    (( 10#$candidate_major > 10#$previous_major )) && return 0
    (( 10#$candidate_major < 10#$previous_major )) && return 1
    (( 10#$candidate_minor > 10#$previous_minor )) && return 0
    (( 10#$candidate_minor < 10#$previous_minor )) && return 1
    (( 10#$candidate_patch > 10#$previous_patch ))
}

case "${1:---check}" in
    --check)
        [[ "$#" -eq 1 || "$#" -eq 0 ]] || { printf 'Usage: %s [--check|--marketing|--build|X.Y.Z [--increment-build]]\n' "$0" >&2; exit 2; }
        printf 'VaultSquire %s (build %s)\n' "$marketing" "$build"
        ;;
    --marketing)
        [[ "$#" -eq 1 ]] || { printf 'Usage: %s --marketing\n' "$0" >&2; exit 2; }
        printf '%s\n' "$marketing"
        ;;
    --build)
        [[ "$#" -eq 1 ]] || { printf 'Usage: %s --build\n' "$0" >&2; exit 2; }
        printf '%s\n' "$build"
        ;;
    --check-history)
        [[ "$#" -eq 1 ]] || { printf 'Usage: %s --check-history\n' "$0" >&2; exit 2; }
        previous_tag=""
        while IFS= read -r tag; do
            [[ "$tag" == "v$marketing" ]] && continue
            tag_version="${tag#v}"
            [[ "$tag_version" =~ $SEMVER_RE ]] || continue
            previous_tag="$tag"
            break
        done < <(git tag --merged HEAD --list 'v*' --sort=-version:refname)
        if [[ -z "$previous_tag" ]]; then
            printf 'No prior release tag; version/build history is valid.\n'
            exit 0
        fi
        previous_version="${previous_tag#v}"
        version_is_greater "$marketing" "$previous_version" || { printf 'Version %s is not greater than %s.\n' "$marketing" "$previous_version" >&2; exit 1; }
        previous_builds="$(git show "$previous_tag:VaultSquire.xcodeproj/project.pbxproj" \
            | /usr/bin/sed -nE 's/^[[:space:]]*CURRENT_PROJECT_VERSION = ([^;]+);/\1/p' \
            | /usr/bin/sort -u)"
        previous_build="$(read_single_value "CURRENT_PROJECT_VERSION in $previous_tag" "$previous_builds")"
        [[ "$previous_build" =~ ^[1-9][0-9]{0,8}$ ]] || { printf 'Invalid build number in %s.\n' "$previous_tag" >&2; exit 1; }
        (( build > previous_build )) || { printf 'Build %s is not greater than %s from %s.\n' "$build" "$previous_build" "$previous_tag" >&2; exit 1; }
        printf 'Version/build are monotonic after %s (build %s).\n' "$previous_tag" "$previous_build"
        ;;
    *)
        version="$1"
        mode="${2:-}"
        [[ "$#" -le 2 && ( -z "$mode" || "$mode" == "--increment-build" ) ]] || { printf 'Usage: %s X.Y.Z [--increment-build]\n' "$0" >&2; exit 2; }
        [[ "$version" =~ $SEMVER_RE ]] || { printf 'Version must use X.Y.Z form without leading zeroes and at most nine digits per component.\n' >&2; exit 2; }
        new_build="$build"
        [[ "$mode" == "--increment-build" ]] && new_build=$((build + 1))
        VERSION="$version" BUILD="$new_build" /usr/bin/perl -pi -e '
            s/(MARKETING_VERSION = )[^;]+;/${1}$ENV{VERSION};/g;
            s/(CURRENT_PROJECT_VERSION = )[^;]+;/${1}$ENV{BUILD};/g;
        ' "$PROJECT"
        VERSION="$version" /usr/bin/perl -pi -e '
            s/(<!-- version -->)[^<]+(<!-- \/version -->)/${1}$ENV{VERSION}${2}/;
        ' "$README"
        /usr/bin/grep -qF "<!-- version -->$version<!-- /version -->" "$README" || { printf 'README version synchronization failed.\n' >&2; exit 1; }
        "$0" --check
        ;;
esac
