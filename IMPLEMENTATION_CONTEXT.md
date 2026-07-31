# History-Isolated Implementation Context

- Status: candidate; reviewer attestation pending
- Candidate created: 2026-07-31
- Planning source: `L-K-M/VaultSquire` tree at
  `3a730f57160341f546d540715d3b00e94fc1d2af`
- Implementation repository: `L-K-M/VaultSquire-Implementation`
- Source license: Apache License 2.0

No application implementation may begin while this record remains pending.

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

Before attestation, verify and record that:

- the candidate root is the repository's only reachable commit;
- the repository is not a GitHub fork and has no inherited branches or tags;
- tracked files match the approved tree plus only the documented license and
  isolation-record changes;
- source-origin scans find no prohibited implementation artifact;
- governance, JSON, links, and whitespace checks pass; and
- `media-sources/icon.png` remains unchanged and is not yet used to generate
  application assets.

## Reviewer Attestation

Pending. An independent reviewer must inspect the candidate root and confirm
that no retained design depends on superseded source-derived research. The
acceptance change must record the reviewer, date, candidate root commit, checks
performed, and any residual limitations before changing this status to
`accepted`.
