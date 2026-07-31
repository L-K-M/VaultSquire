# History-Isolated Implementation Context

- Status: accepted
- Candidate created: 2026-07-31
- Accepted: 2026-07-31
- Planning source: `L-K-M/VaultSquire` tree at
  `3a730f57160341f546d540715d3b00e94fc1d2af`
- Implementation repository: `L-K-M/VaultSquire-Implementation`
- Attested candidate root: `81cfb67df4ab7e06bdd1961ef98168b6dcf1ca9c`
- Source license: Apache License 2.0

This acceptance applies only to work derived from the attested root and its
reviewed descendants. [`WORKSTREAM_0.md`](WORKSTREAM_0.md) records the completed
governance/evidence gate; application implementation begins with Workstream 1
and remains subject to every later exit criterion.

## Isolation Procedure

1. A new empty private GitHub repository was created. It was not created as a
   fork and inherited no refs, tags, pull-request refs, or Git objects from the
   planning repository.
2. Only the current approved tree at the planning source commit above was
   exported with `git archive` into the empty checkout. The planning
   repository's `.git` directory and earlier commits were not exported.
3. The selected Apache License 2.0 decision and this isolation record were
   applied before the candidate root commit.
4. No application code, package manifest, Xcode project, project generator,
   product build script, product CI, dependency artifact, generated icon, test
   fixture, provider output, or external source checkout was added.

## Approved Inputs

Implementation in this repository may use only:

- the approved requirements and governance records in this root;
- public Apple platform documentation;
- recorded public protocol facts and independently generated synthetic
  black-box fixtures;
- reviewed general-purpose dependencies with complete provenance records; and
- the separately installed official Proton Pass CLI through the documented
  process boundary.

## Excluded Inputs

- No superseded planning commit is implementation context.
- No Keyguard source, checkout, source-derived note, test, schema, design, UI,
  string, or asset may enter this repository, an implementation prompt, or a
  build environment.
- Pinned Bitwarden, Vaultwarden, and Proton source references remain protocol
  evidence only. Their source expression is not implementation input.
- Production vault data, credentials, tokens, CLI output, databases, logs, and
  support bundles are prohibited.

## Candidate Verification

The following checks were completed against the attested root:

- Git has one reachable root commit, one `main` branch, and no tags.
- GitHub reports `isFork: false`, no parent repository, and private visibility.
- Files from the planning snapshot are byte-identical except for the documented
  Apache-2.0 and implementation-context governance changes.
- No application source, Xcode or package manifest, project generator, product
  build script, product dependency, test fixture, or generated asset exists.
- All 54 local Markdown links and fragments resolve; JSON, governance,
  whitespace, and forbidden-file checks pass locally.
- The canonical Apache License text has SHA-256
  `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`.
- `media-sources/icon.png` is unchanged at SHA-256
  `438060d1a8740e69cb1330ee60c218e23556edcf6c4a5d6333ee21b051201eeb`
  and has not been used to generate application assets.

## Reviewer Attestation

- Reviewer: `L-K-M`, project owner
- Attestation date: 2026-07-31
- Attested commit: `81cfb67df4ab7e06bdd1961ef98168b6dcf1ca9c`

The reviewer inspected and explicitly approved the exact candidate root as a
history-isolated implementation context, confirming that its retained design
does not depend on superseded source-derived research.

This attestation does not approve a dependency, protocol implementation,
cryptographic construction, product release, or generated asset. GitHub-hosted
CI was unable to allocate a runner because the account's Actions budget was
exhausted; equivalent repository-hygiene checks passed locally. The current
Linux host also cannot satisfy macOS/Xcode, signing, notarization, accessibility,
hardware, or performance gates. Those gates remain blocking at their documented
workstreams.
