#!/usr/bin/env bash
set -euo pipefail

EXPECTED_REPOSITORY="L-K-M/VaultSquire"
REPOSITORY="${GITHUB_REPOSITORY:-$EXPECTED_REPOSITORY}"
CHECK_IMMUTABLE_RELEASES="${CHECK_IMMUTABLE_RELEASES:-true}"
command -v gh >/dev/null 2>&1 || { printf 'gh is required to inspect release controls.\n' >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { printf 'jq is required to inspect release controls.\n' >&2; exit 1; }
[[ "$REPOSITORY" == "$EXPECTED_REPOSITORY" ]] || {
    printf 'Release controls may be inspected only for %s.\n' "$EXPECTED_REPOSITORY" >&2
    exit 1
}
[[ "$(gh api user | jq -r '.login')" == "L-K-M" ]] || {
    printf 'RELEASE_ADMIN_TOKEN must belong to the VaultSquire repository owner.\n' >&2
    exit 1
}
repository="$(gh api "repos/$REPOSITORY")"
[[ "$(printf '%s' "$repository" | jq -r '.default_branch')" == "main" ]] || {
    printf 'The repository default branch must remain main.\n' >&2
    exit 1
}

environment="$(gh api "repos/$REPOSITORY/environments/release")"
printf '%s' "$environment" | jq -e '.can_admins_bypass == false' >/dev/null || {
    printf 'Administrators must not be able to bypass release environment protection.\n' >&2
    exit 1
}
printf '%s' "$environment" | jq -e '
    .protection_rules
    | any(.type == "required_reviewers"
          and .prevent_self_review == true
          and (.reviewers | length) >= 1)
' >/dev/null || {
    printf 'The release environment must require a non-self reviewer.\n' >&2
    exit 1
}

required_secrets='["AC_API_ISSUER_ID","AC_API_KEY_BASE64","AC_API_KEY_ID","APPLE_TEAM_ID","DEVELOPER_ID_P12_BASE64","DEVELOPER_ID_P12_PASSWORD","KEYCHAIN_PASSWORD","MACOS_APP_PROFILE_BASE64","RELEASE_ADMIN_TOKEN"]'
environment_secrets="$(gh api "repos/$REPOSITORY/environments/release/secrets?per_page=100" | jq -c '[.secrets[].name] | sort')"
[[ "$environment_secrets" == "$required_secrets" ]] || {
    printf 'The release environment secret names do not match the reviewed allowlist.\n' >&2
    exit 1
}
for secret_name in $(printf '%s' "$required_secrets" | jq -r '.[]'); do
    gh api "repos/$REPOSITORY/environments/release/secrets/$secret_name" >/dev/null || {
        printf 'Cannot inspect release environment secret %s.\n' "$secret_name" >&2
        exit 1
    }
done
repository_secrets="$(gh api "repos/$REPOSITORY/actions/secrets?per_page=100" | jq -c '[.secrets[].name]')"
printf '%s' "$repository_secrets" | jq -e --argjson required "$required_secrets" \
    'all(.[]; . as $name | $required | index($name) | not)' >/dev/null || {
        printf 'A release credential is configured as a repository secret.\n' >&2
        exit 1
    }
owner_type="$(printf '%s' "$repository" | jq -r '.owner.type')"
if [[ "$owner_type" != "User" ]]; then
    printf 'VaultSquire must remain under its reviewed personal repository owner.\n' >&2
    exit 1
fi

if [[ "$CHECK_IMMUTABLE_RELEASES" == "true" ]]; then
    gh api "repos/$REPOSITORY/immutable-releases" \
        | jq -e '.enabled == true' >/dev/null || {
            printf 'Immutable GitHub Releases must be enabled.\n' >&2
            exit 1
        }
elif [[ "$CHECK_IMMUTABLE_RELEASES" != "false" ]]; then
    printf 'CHECK_IMMUTABLE_RELEASES must be true or false.\n' >&2
    exit 2
fi

rulesets="$(gh api "repos/$REPOSITORY/rulesets?per_page=100")"
branch_ok=false
tag_ok=false

while IFS= read -r ruleset_id; do
    [[ -n "$ruleset_id" ]] || continue
    ruleset="$(gh api "repos/$REPOSITORY/rulesets/$ruleset_id")"
    if printf '%s' "$ruleset" | jq -e '
        .target == "branch"
        and .enforcement == "active"
        and .current_user_can_bypass == "never"
        and has("bypass_actors")
        and (.bypass_actors | length == 0)
        and (.conditions.ref_name.exclude | length == 0)
        and (.conditions.ref_name.include | any(. == "refs/heads/main" or . == "~DEFAULT_BRANCH" or . == "~ALL"))
        and (.rules | any(.type == "pull_request"
                          and .parameters.required_approving_review_count >= 2
                          and .parameters.dismiss_stale_reviews_on_push == true
                          and .parameters.require_last_push_approval == true))
    ' >/dev/null; then
        branch_ok=true
    fi
    if printf '%s' "$ruleset" | jq -e '
        .target == "tag"
        and .enforcement == "active"
        and .current_user_can_bypass == "never"
        and has("bypass_actors")
        and (.bypass_actors | length == 0)
        and (.conditions.ref_name.exclude | length == 0)
        and (.conditions.ref_name.include | any(. == "refs/tags/v*" or . == "~ALL"))
        and (.rules | any(.type == "update"))
        and (.rules | any(.type == "deletion"))
    ' >/dev/null; then
        tag_ok=true
    fi
done < <(printf '%s' "$rulesets" | jq -r '.[] | select(.enforcement == "active") | .id')

$branch_ok || { printf 'main must require two approving reviews without bypass.\n' >&2; exit 1; }
$tag_ok || { printf 'v* tags must reject updates and deletion without bypass.\n' >&2; exit 1; }
if [[ "$CHECK_IMMUTABLE_RELEASES" == "true" ]]; then
    printf 'Verified protected release environment, scoped secrets, main, tags, and immutable releases.\n'
else
    printf 'Verified protected release environment, scoped secrets, main, and tags.\n'
fi
