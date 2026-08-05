#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_ONLY=false
EXPECTED_VERSION=""
EXPECTED_BUILD=""
SEMVER_RE='^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --status) STATUS_ONLY=true ;;
        --version)
            [[ "$#" -ge 2 ]] || { printf 'Missing value for --version.\n' >&2; exit 2; }
            EXPECTED_VERSION="$2"
            shift
            ;;
        --build)
            [[ "$#" -ge 2 ]] || { printf 'Missing value for --build.\n' >&2; exit 2; }
            EXPECTED_BUILD="$2"
            shift
            ;;
        *) printf 'Usage: %s [--status] [--version X.Y.Z] [--build N]\n' "$0" >&2; exit 2 ;;
    esac
    shift
done

CONFIG="$ROOT/.github/release-eligibility.env"
eligible="$(/usr/bin/awk -F= '$1 == "RELEASE_ELIGIBLE" { print $2 }' "$CONFIG")"
eligible_version="$(/usr/bin/awk -F= '$1 == "RELEASE_ELIGIBLE_VERSION" { print $2 }' "$CONFIG")"
eligible_build="$(/usr/bin/awk -F= '$1 == "RELEASE_ELIGIBLE_BUILD" { print $2 }' "$CONFIG")"
eligible_source_commit="$(/usr/bin/awk -F= '$1 == "RELEASE_ELIGIBLE_SOURCE_COMMIT" { print $2 }' "$CONFIG")"
record="$(/usr/bin/awk -F= '$1 == "RELEASE_ELIGIBILITY_RECORD" { print $2 }' "$CONFIG")"

if [[ "$eligible" != "true" && "$eligible" != "false" ]]; then
    printf 'Invalid RELEASE_ELIGIBLE value in %s\n' "$CONFIG" >&2
    exit 1
fi
if [[ -z "$record" || ! -f "$ROOT/$record" ]]; then
    printf 'Release eligibility record is missing: %s\n' "${record:-<unset>}" >&2
    exit 1
fi

if [[ "$eligible" == "true" ]]; then
    [[ "$eligible_version" =~ $SEMVER_RE ]] || {
        printf 'RELEASE_ELIGIBLE_VERSION must use X.Y.Z form when enabled.\n' >&2
        exit 1
    }
    [[ "$eligible_build" =~ ^[1-9][0-9]{0,8}$ ]] || {
        printf 'RELEASE_ELIGIBLE_BUILD must be a positive integer when enabled.\n' >&2
        exit 1
    }
    [[ "$eligible_source_commit" =~ ^[0-9a-f]{40}$ ]] || {
        printf 'RELEASE_ELIGIBLE_SOURCE_COMMIT must be a full Git object ID when enabled.\n' >&2
        exit 1
    }
    if [[ -n "$EXPECTED_VERSION" && "$EXPECTED_VERSION" != "$eligible_version" ]]; then
        printf 'Release %s is not the approved candidate v%s.\n' "$EXPECTED_VERSION" "$eligible_version" >&2
        exit 1
    fi
    if [[ -n "$EXPECTED_BUILD" && "$EXPECTED_BUILD" != "$eligible_build" ]]; then
        printf 'Build %s is not the approved candidate build %s.\n' "$EXPECTED_BUILD" "$eligible_build" >&2
        exit 1
    fi
    status_count="$(/usr/bin/grep -c '^\- Status: eligible$' "$ROOT/$record" || true)"
    candidate_count="$(/usr/bin/grep -c "^\- Release candidate: v$eligible_version (build $eligible_build)$" "$ROOT/$record" || true)"
    source_count="$(/usr/bin/grep -c "^\- Candidate source commit: $eligible_source_commit$" "$ROOT/$record" || true)"
    approval_count="$(/usr/bin/grep -c '^\- Release eligibility: enabled$' "$ROOT/$record" || true)"
    if [[ "$status_count" -ne 1 || "$candidate_count" -ne 1 || "$source_count" -ne 1 || "$approval_count" -ne 1 ]]; then
        printf 'Release eligibility record does not approve exactly v%s build %s.\n' "$eligible_version" "$eligible_build" >&2
        exit 1
    fi
    [[ "$(/usr/bin/grep -c '^\- Status: blocked$' "$ROOT/$record" || true)" -eq 0 ]] || { printf 'Eligible record still contains blocked status.\n' >&2; exit 1; }
    [[ "$(/usr/bin/grep -c '^\- Release candidate:' "$ROOT/$record" || true)" -eq 1 ]] || { printf 'Eligible record contains multiple candidate markers.\n' >&2; exit 1; }
    [[ "$(/usr/bin/grep -c '^\- Candidate source commit:' "$ROOT/$record" || true)" -eq 1 ]] || { printf 'Eligible record contains multiple source markers.\n' >&2; exit 1; }
    current_commit="$(git -C "$ROOT" rev-parse HEAD)"
    first_parent="$(git -C "$ROOT" rev-parse HEAD^1)"
    [[ "$first_parent" == "$eligible_source_commit" ]] || { printf 'Eligibility commit is not directly based on the approved source commit.\n' >&2; exit 1; }
    changed_files="$(git -C "$ROOT" diff --name-only "$eligible_source_commit" "$current_commit")"
    expected_files=$'.github/release-eligibility.env\nRELEASE_ELIGIBILITY.md'
    [[ "$changed_files" == "$expected_files" ]] || { printf 'Eligibility commit contains changes beyond the two approval records.\n' >&2; exit 1; }
    if /usr/bin/grep -q '^## Current Blockers$' "$ROOT/$record"; then
        printf 'Release eligibility record still contains Current Blockers.\n' >&2
        exit 1
    fi
    [[ -x "$ROOT/scripts/generate-sbom.sh" ]] || {
        printf 'A reviewed release SBOM generator is required before eligibility.\n' >&2
        exit 1
    }
    /usr/bin/grep -q 'scripts/generate-sbom.sh' "$ROOT/.github/workflows/release.yml" || {
        printf 'The release workflow does not invoke the reviewed SBOM generator.\n' >&2
        exit 1
    }
    /usr/bin/grep -q '^VaultSquire currently has no application dependencies\.' "$ROOT/DEPENDENCIES.md" || {
        printf 'The SBOM generator must be extended for the adopted dependency inventory.\n' >&2
        exit 1
    }
    printf 'Release automation is enabled for v%s build %s by %s.\n' "$eligible_version" "$eligible_build" "$record"
    exit 0
fi

[[ -z "$eligible_version" ]] || { printf 'RELEASE_ELIGIBLE_VERSION must be empty while blocked.\n' >&2; exit 1; }
[[ -z "$eligible_build" ]] || { printf 'RELEASE_ELIGIBLE_BUILD must be empty while blocked.\n' >&2; exit 1; }
[[ -z "$eligible_source_commit" ]] || { printf 'RELEASE_ELIGIBLE_SOURCE_COMMIT must be empty while blocked.\n' >&2; exit 1; }
[[ "$(/usr/bin/grep -c '^\- Status: blocked$' "$ROOT/$record" || true)" -eq 1 ]] || {
    printf 'Blocked release record must contain exactly one blocked status.\n' >&2
    exit 1
}
if /usr/bin/grep -q '^\- Release eligibility: enabled$' "$ROOT/$record"; then
    printf 'Blocked release record unexpectedly contains the approval marker.\n' >&2
    exit 1
fi
printf 'Release automation is blocked by %s.\n' "$record"
printf 'No release, private preview, or distributed artifact may be produced yet.\n'
$STATUS_ONLY && exit 0
exit 1
