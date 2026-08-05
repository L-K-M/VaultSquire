# Release Eligibility

- Status: blocked
- Owner: `L-K-M`
- Last reviewed: 2026-08-01

This record controls the machine-readable release stop gate. It does not replace
the controlling criteria in [`WORKSTREAM_1.md`](WORKSTREAM_1.md),
[`DELIVERY.md`](DELIVERY.md), or
[`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md).

## Required Evidence

A release owner may enable automation only after recording all of the following:

- every Workstream 1 Exit Evidence row is passed, except that only the three
  not-implemented Proton-process rows may instead be explicitly withdrawn by a
  further accepted ADR as permitted by ADR 0006;
- Phase 0 is certified complete under `PLAN.md`;
- Workstreams 2 through 7 are complete in the sequence required by `DELIVERY.md`;
- Workstream 8's pre-artifact hardening, release-pipeline review, vulnerability
  intake, and safe candidate-build prerequisites are complete;
- the release feature manifest is frozen and reviewed;
- every applicable release-candidate and stop-ship item that does not depend on
  the final signed candidate artifact has an immutable evidence reference;
- every artifact-dependent gate is explicitly pending with an owner and named
  clean-Mac procedure; no such gate is claimed as passed before the draft exists;
- the App Group, Developer ID, notarization, clean-Mac, accessibility,
  performance, leakage, SBOM, vulnerability, provenance, checksum, rollback,
  emergency-release, and update-revocation evidence has named owners;
- two focused human reviewers approve the release-pipeline and eligibility change.

## Enabling Procedure

1. Replace `Status: blocked` above with `Status: eligible`.
2. Add one exact `- Release candidate: vX.Y.Z (build N)` line, one exact
   `- Candidate source commit: <full SHA>` line, and one exact
   `- Release eligibility: enabled` line below the status metadata.
3. Remove the Current Blockers section after every blocker has evidence.
4. Set `RELEASE_ELIGIBLE=true`, `RELEASE_ELIGIBLE_VERSION=X.Y.Z`,
   `RELEASE_ELIGIBLE_BUILD=N`, and `RELEASE_ELIGIBLE_SOURCE_COMMIT=<full SHA>` in
   `.github/release-eligibility.env` in the same reviewed commit. That commit may
   change only the eligibility environment and this record, and its first parent
   must be the named source commit.
5. Run `./scripts/check-repository.sh` and every pre-artifact item from the
   release-candidate matrix. List each artifact-dependent item as pending with
   its owner and post-draft procedure.

`scripts/check-release-eligibility.sh` requires both the Boolean and the exact
candidate-specific approval markers. None is present now. Do not add them
speculatively. After a draft candidate is accepted or rejected, a reviewed
commit returns this record and the environment file to their blocked state
before another candidate is approved.

Eligibility authorizes only the protected workflow to build one exact signed
candidate and retain it in a restricted draft prerelease. It does not authorize
preview distribution or final publication. After the workflow, all
artifact-dependent Workstream 8 release-candidate and stop-ship evidence must be
recorded, but the draft still may not be published or distributed. Final
publication remains unimplemented until a candidate-bound final-approval marker,
evidence-set identifier, independent reviewer gate, and asset checksum and
attestation revalidation command are added and reviewed.

If the signed tag workflow fails before it creates a draft, immediately return
the eligibility records to blocked. Because protected tags are immutable, bump
the version and build in a new reviewed candidate; never move or reuse the failed
tag.

## Current Blockers

- `WORKSTREAM_1.md` contains outstanding evidence and not-implemented rows.
- Workstreams 2 through 7 and Workstream 8 pre-artifact hardening have not completed.
- No release feature manifest or release-candidate evidence set exists.
- Developer ID, App Group provisioning, notarization, clean-Mac installation,
  independent checksum publication, and incident drills are unverified.
- The protected `release` environment, two-reviewer `main` ruleset, immutable
  `v*` tag ruleset, and immutable GitHub Releases are not configured.

The guarded workflow in `.github/workflows/release.yml` is reviewable future
infrastructure only. Its presence is not release evidence.
