# ADR 0003: Dependency Adoption Policy

- Status: Accepted
- Date: 2026-07-31
- Owner: `L-K-M`
- Required second reviewer: independent security or supply-chain reviewer
- Controlling documents/sections: `PLAN.md` Workstream 0;
  `SECURITY_AND_TESTING.md` supply-chain requirements

## Context

A password manager executes dependencies inside a process that handles keys and
plaintext. Semantic version declarations alone do not establish provenance,
license compatibility, binary composition, or safe update behavior.

## Decision

- Prefer Apple public APIs and small app-owned boundaries where they are
  sufficient.
- A candidate record is research, not permission to add a package manifest or
  artifact.
- Before adoption, record exact version, commit/tree, canonical origin, artifact
  checksum or signature, license and notices, complete transitive inventory,
  secret surface, owner, update cadence, and removal plan.
- Pin one exact reviewed revision. Do not use branches, open version ranges,
  automatic package updates, prereleases, or automatic dependency merges.
- `L-K-M` owns platform, cryptography, storage, supply-chain, and release updates
  during the solo-project phase. Cryptography, storage binaries, updater, and
  release-pipeline changes require a second independent reviewer.
- Re-run source, binary, license, SBOM, architecture, leakage, cancellation, and
  applicable compatibility checks for every update.
- Unknown provenance, moved refs, unexplained binary contents, incompatible
  licenses, or missing security ownership fail closed.

## Current Candidates

The candidate register in [`DEPENDENCIES.md`](../../DEPENDENCIES.md) and detailed
assessments under [`docs/dependencies`](../dependencies/README.md) cover GRDB,
SQLCipher, Argon2id, KeyboardShortcuts, and Sparkle. The Apple hot-key fallback
is an OS/SDK comparison surface whose exact toolchain baseline is a Workstream 1
gate, not a third-party dependency candidate. Nothing is adopted by this ADR.

## Security And Privacy Consequences

An in-process dependency can observe unlocked memory even when its intended API
is narrow. Boundaries minimize values passed to dependencies but cannot sandbox
them from the host process. Binary dependencies require recursive signature and
component inspection in the final app.

## Alternatives

Trusting tags, package-manager metadata, popularity, or a clean vulnerability
scan alone is rejected. Vendoring provider/client implementation code is
prohibited regardless of license.

## Verification

Each adoption PR must satisfy its assessment's positive, negative,
cancellation, resource, leakage, packaging, and removal gates and update the
SBOM/notices. Workstream 0 verifies only that candidates are fully identified.

## Rollback Or Revisit Trigger

Revisit when a candidate becomes unmaintained, changes license or ownership,
cannot meet the supported toolchain, gains unexplained transitives, or fails a
security or removal drill.
