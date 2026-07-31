# ADR 0002: Provider Boundary

- Status: Accepted
- Date: 2026-07-31
- Owner: `L-K-M`
- Controlling documents/sections: `PLAN.md` section 6; `ARCHITECTURE.md`
  sections 5 and 7

## Context

Vaultwarden exposes a remote encrypted-vault protocol. Proton Pass support is
available only through a separately installed official CLI that emits decrypted,
lossy JSON. Treating them as one protocol or crypto model would erase critical
security and conflict differences.

## Decision

- Implement one small compiled provider facade, not a plug-in framework or one
  protocol per conceptual seam.
- Share only compound identity, lifecycle state, exact capabilities, cache
  envelope metadata, narrow immutable display/search projections, and opaque
  sync state.
- Namespace every local identity by provider, account, provider space/share, and
  item identifier.
- Keep Vaultwarden authentication, cryptography, native ciphertext, revisions,
  sync, permissions, and conflict behavior inside `VaultwardenProvider`.
- Keep Proton executable validation, process execution, JSON mapping, app-level
  cache encryption, complete refresh, and command capabilities inside
  `ProtonCLIProvider`.
- Never implement Proton's private API or cryptography, and never link or bundle
  Proton code.
- Never flatten Vaultwarden native records for writes or reconstruct a Proton
  write from lossy CLI output.

## Security And Privacy Consequences

Every action path consumes capability values at a use-case boundary. Lock and
session-generation rules apply before provider publication. Vaultwarden caches
provider-native ciphertext; Proton output is wrapped immediately with
VaultSquire AEAD and remains explicitly lossy.

## Alternatives

A universal crypto API, runtime plug-ins, and shared write model are rejected.
They imply false interchangeability and broaden the secret and compatibility
surface before two providers exist.

## Verification

Workstream 2 must compile one facade with a fake provider and test identity
collisions, unsupported actions, cancellation, lock races, fidelity metadata,
and unknown fields before either production provider is attached.

## Rollback Or Revisit Trigger

Revisit only if a third provider demonstrates a repeated seam that cannot be
expressed by the narrow facade without moving provider-specific security rules
into shared code.
