# ADR 0004: Initial Compatibility Support

- Status: Accepted
- Date: 2026-07-31
- Owner: `L-K-M`
- Controlling documents/sections: `PLAN.md` server support policy;
  `SECURITY_AND_TESTING.md` provider matrices

## Context

Neither Vaultwarden's private client API nor the Proton CLI machine interface
provides VaultSquire a broad compatibility promise. Support must identify exact
tested artifacts rather than infer behavior from names or nearby versions.

## Decision

- Initial Vaultwarden target: `1.37.1`, source revision
  `2629bcbe1380c894e3a7f52cafcac3988edb8fbb`, and OCI index digest
  `sha256:ebdfe70701c60ac0c28c697e787cea767d7972940b786037b29fe0d507f821e8`.
- Pull and run the container by digest, never by mutable tag alone.
- Account encryption support starts with authenticated V1. Legacy type 0 and V2
  fail closed with preserved ciphertext and explicit compatibility guidance.
- The application version and `Bitwarden-Client-Version` compatibility value are
  independent. The latter remains unset until contract tests justify it.
- Add a previous Vaultwarden release only after the initial target passes and is
  explicitly declared supported.
- Proton CLI `2.2.3` is a command-contract candidate, not a supported version.
  `2.2.4` and every unlisted version are unsupported until exact executable,
  schema, process, and live disposable-account tests pass.
- Initial application architecture support is Apple Silicon `arm64` only.

## Security And Privacy Consequences

Displayed version strings are diagnostic evidence, not Vaultwarden capability
gates. Proton command capabilities fail closed by exact executable identity and
version. Test artifacts contain synthetic data only.

## Alternatives

Floating `latest` containers, semver ranges, optimistic Proton patch support,
and brand/version-only Vaultwarden feature checks are rejected.

## Verification

The evidence register records every immutable input. Provider PRs must run their
complete contract matrices against digest-pinned or identity-pinned artifacts
before declaring support.

## Rollback Or Revisit Trigger

Revisit when a supported provider release is unavailable, vulnerable, or no
longer representative, or when a tested compatibility window can be expanded
without weakening fail-closed behavior.
