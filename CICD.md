# CI/CD

VaultSquire has implemented product CI and a fail-closed future release path.
The latter is infrastructure, not authorization to distribute the current app.
[`WORKSTREAM_1.md`](WORKSTREAM_1.md) and
[`docs/adr/0006-workstream-1-merge-with-outstanding-evidence.md`](docs/adr/0006-workstream-1-merge-with-outstanding-evidence.md)
prohibit a release, private preview, or distributed artifact while their gates
remain outstanding.

## Workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `repository-hygiene.yml` | Pull requests, pushes to `main`, manual | Portable governance, secret-material, version, and repository checks. |
| `macos-product.yml` | Pull requests, pushes to `main`, manual, reusable call | Xcode 26.3 tests, three ad-hoc products, binary inspection, and Workstream 1 trend fixtures. |
| `release.yml` | Strict release tags once eligible | Re-prove, Developer ID sign, provision, notarize, inspect, attest, and create a draft prerelease. It currently stops at its first gate. |
| `zai-code-review.yml` | Eligible same-repository pull requests with `glm-review` | Optional external GLM review. |

All checkout actions are immutable-SHA pinned and disable credential persistence.
Build and hygiene jobs have read-only repository permissions; the optional GLM
review separately has issue/PR write access. The credentialed release job alone
has release and attestation permissions, runs in the `release` environment, and
cannot start until the uncredentialed eligibility and CI jobs pass. Release
automation additionally verifies that the environment requires non-self review,
`main` requires two approvals, `v*` tags reject updates/deletion, and immutable
GitHub Releases are enabled. Those repository controls are not configured yet.

## Local Builds

On native Apple Silicon with Xcode 26.3:

```sh
./scripts/build.sh
./scripts/build.sh DirectProbe
./scripts/build.sh SandboxProbe
./scripts/build.sh --no-reveal
./scripts/build.sh --check
```

`build.sh` is a stable facade over `build-local.sh`; it does not substitute the
generic shared build engine because VaultSquire must retain its exact arm64
destination, configuration-specific entitlements, ad-hoc Hardened Runtime
signature, independent entitlement allowlist, and linked-image inspection.
The generated ZIPs under `dist/` are local verification outputs only. They are
not reproducible byte-for-byte and must not be distributed.

To install a local copy that can exercise the App Group entitlement:

```sh
DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/build.sh --install
DEVELOPMENT_TEAM=XXXXXXXXXX ./scripts/build.sh --install --run
```

This path requires the Apple Developer account to own
`ch.lkmc.VaultSquire` and `group.ch.lkmc.VaultSquire`. Xcode obtains an Apple
Development profile, and the script verifies the signature, embedded profile,
Team ID, identifiers, App Group, version, architecture, and linked images before
and after copying the app to `/Applications`. The check proves static
provisioning only; a runtime App Group create/read/delete smoke test is still a
Workstream 8 release requirement.

## Versioning

The Xcode project is authoritative. Every app configuration contains the same:

- `MARKETING_VERSION`, currently `0.1.0`;
- `CURRENT_PROJECT_VERSION`, currently `1`.

Use these read-only commands on any host:

```sh
./scripts/version.sh --check
./scripts/version.sh --marketing
./scripts/version.sh --build
```

`scripts/version.sh X.Y.Z --increment-build` is the reviewed mutation command;
it keeps all three Xcode configurations and the README source marker synchronized.
Commit that change and all Workstream 8A infrastructure through the normal
two-reviewer pull-request process, then update the candidate-specific eligibility
record in one final reviewed commit containing only the two approval files.
`scripts/release.sh X.Y.Z` does not mutate source: it requires the reviewed
version/build already on `origin/main`, verifies Xcode and GitHub release
protections, and creates a cryptographically signed `vX.Y.Z` tag. With `--push`,
it pushes only that tag.

The README version marker is synchronized by `scripts/version.sh`. It labels the
source version only until supported releases exist.

## Release Gate

`.github/release-eligibility.env` is the machine-readable stop gate. It remains:

```text
RELEASE_ELIGIBLE=false
RELEASE_ELIGIBLE_VERSION=
RELEASE_ELIGIBLE_BUILD=
RELEASE_ELIGIBLE_SOURCE_COMMIT=
RELEASE_ELIGIBILITY_RECORD=RELEASE_ELIGIBILITY.md
```

Changing the Boolean alone is insufficient. When all Workstream 1 gates and the
pre-artifact Workstream 8 candidate gates have recorded evidence and owner approval,
[`RELEASE_ELIGIBILITY.md`](RELEASE_ELIGIBILITY.md) must identify the exact
version/build/source commit and contain one approval marker. Enabling either side without the
other fails closed. The release-pipeline change requires two focused human reviewers under
[`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md).

Until then:

- `scripts/release.sh --check` reports the blocked state without mutation;
- an actual `scripts/release.sh X.Y.Z` exits before any Git or release action;
- `release.yml` exits in an Ubuntu job before entering the protected environment,
  accessing credentials, running Xcode, or creating an artifact.

## Future Signed Release

After the version/build commit and candidate-specific eligibility commit are on
protected `main`, cut from a clean matching checkout on macOS:

```sh
./scripts/release.sh X.Y.Z
./scripts/release.sh X.Y.Z --push
```

The tag workflow accepts only a cryptographically signed `vX.Y.Z` tag on the
candidate-specific eligibility commit at current `origin/main`, and has no
unsigned or ad-hoc fallback. It will:

1. Re-run the complete macOS product workflow at the tagged commit.
2. Require all Developer ID, provisioning, notarization, and hosting-control
   inspection secrets in the protected environment.
3. Validate and install an unexpired Developer ID profile for the exact bundle
   ID and App Group.
4. Archive and export with Xcode using manual Developer ID signing.
5. Verify the final version/build, exact arm64 architecture, Hardened Runtime,
   timestamp, Team ID, identifiers, provisioning profile, reviewed entitlements,
   designated requirement, and linked images.
6. Launch-smoke the exported app, then notarize and staple it.
7. Create and sign the DMG, notarize and staple it, and inspect the app from a
   read-only mounted image.
8. Create a `ditto` ZIP and inspect the extracted copy.
9. Produce SHA-256 checksums, a complete file-level SPDX 2.3 SBOM, complete
   notarization logs, and GitHub build-provenance attestations.
10. Create a draft prerelease for human review. Nothing is published as a final
    release automatically.

The restricted draft is candidate evidence, not a preview or release. This
workflow does not by itself satisfy the clean-Mac, runtime App Group,
accessibility, performance, leakage, vulnerability, emergency-update, or updater
gates in `SECURITY_AND_TESTING.md`. Those remain release-candidate evidence.
Final publication automation is intentionally absent until it can require a
candidate-bound final approval and revalidate the draft assets, checksums, and
attestations after all manual evidence is recorded.

## Protected Secrets

Configure these only in a protected `release` environment with required human
reviewers:

| Secret | Purpose |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | Base64 Developer ID Application certificate and private key. |
| `DEVELOPER_ID_P12_PASSWORD` | Password for the PKCS#12 file. |
| `KEYCHAIN_PASSWORD` | Password for the ephemeral signing Keychain. |
| `APPLE_TEAM_ID` | Verified ten-character Apple Developer Team ID. |
| `MACOS_APP_PROFILE_BASE64` | Base64 Developer ID provisioning profile for the exact bundle ID and App Group. |
| `AC_API_KEY_BASE64` | Base64 App Store Connect API `.p8` key for notarization. |
| `AC_API_KEY_ID` | App Store Connect API key identifier. |
| `AC_API_ISSUER_ID` | App Store Connect issuer identifier. |
| `RELEASE_ADMIN_TOKEN` | Fine-grained personal access token owned by `L-K-M`, selected only for `L-K-M/VaultSquire`, with repository permissions `Administration: write` (needed because GitHub hides ruleset bypass actors from read-only callers), `Environments: read`, `Secrets: read`, and implicit `Metadata: read`. No organization permission or other repository access is permitted. It cannot read secret values. |

`ZAI_API_KEY` is a repository-level optional review secret, not a release
environment secret.

Signing keys and profiles are recovery assets. Never commit, paste, or expose
them in issue text, pull requests, logs, prompts, or support material.
The administration token is also sensitive and broader than an ordinary CI
token. Rotate it on a short schedule. `check-release-hosting.sh` verifies its
owner, repository, and ability to read every required control; GitHub exposes no
API that proves a fine-grained token has no unneeded grant, so the environment
configuration itself requires manual two-person inspection before eligibility.

## Manual Gates

The protected workflow intentionally cannot claim several required results.
Before approving a draft prerelease, the release owner must record the applicable
`SECURITY_AND_TESTING.md` release-candidate and stop-ship evidence, including:

- clean, quarantined download/install and offline first launch on named Macs;
- runtime App Group access and clean removal of its smoke-test file;
- accessibility, Spaces/full-screen, and named-hardware performance results;
- recursive final-artifact and canary leakage inspection;
- dependency vulnerability/license review and SBOM review;
- rollback, emergency release, signing compromise, and update revocation drills;
- upgrade checks from every supported prior VaultSquire version;
- updater metadata signing and downgrade rejection once an updater exists.

Checksums are attached to the draft release and covered by the provenance
attestation, but `SECURITY_AND_TESTING.md` also requires independent checksum
publication before a final release.

The current app has no adopted package dependency. `generate-sbom.py` inventories
every tracked source and regular file in the signed app, relates the artifact to
its source commit, and fails if one of the currently supported Apple package
manifests or nested code appears.
When a dependency is adopted, its assessment must extend this generator before
the same commit can become release-eligible; silently incomplete SBOMs are not
accepted.

The restricted draft remains mutable by GitHub design. No documented command
publishes it. The eventual publication workflow must verify a separate final
approval, re-download every draft asset, compare checksums and attestations, and
then publish once so immutable-release protection begins.
