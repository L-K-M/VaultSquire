# ADR 0001: Platform And Distribution Baseline

- Status: Accepted
- Date: 2026-07-31
- Owner: `L-K-M`
- Controlling documents/sections: `PLAN.md` sections 5 and 7;
  `ARCHITECTURE.md` decisions D1, D9, and D10

## Context

VaultSquire needs one original Apple-platform identity and a release boundary
before project scaffolding. No macOS runner, Apple Team ID, signing identity, or
notarization credential is available in the current Linux environment.

## Decision

- Target macOS 14 or later with Swift 6 strict concurrency.
- Ship Apple Silicon `arm64` first. Intel support is out of the initial manifest
  and requires a later ADR plus native Intel CI and release testing.
- Reserve bundle identifier `ch.lkmc.VaultSquire`.
- Reserve App Group identifier `group.ch.lkmc.VaultSquire` from the first build.
- Record the Apple Team ID only after access to the actual signing team is
  verified; do not invent or commit a placeholder entitlement value.
- Use SwiftUI with focused AppKit integration in one modular app target.
- Distribute directly with Developer ID, Hardened Runtime, notarization, and
  stapling. The Mac App Store is not an initial target.
- Prefer App Sandbox only if the Workstream 1 Proton CLI feasibility spike proves
  executable selection, child-process inheritance, session, and keyring access.
  Otherwise use the documented non-sandboxed Hardened Runtime fallback.
- Add no privileged helper.

## Security And Privacy Consequences

The final entitlement set must be allowlisted and recursively inspected. App
Group storage is selected before the first database to avoid a secret-bearing
container migration. Direct distribution makes update signing, release-hosting,
notarization, and emergency revocation project responsibilities.

## Alternatives

- Universal `arm64`/`x86_64` output is deferred because no native Intel test
  capability exists.
- Mac App Store distribution is rejected while the external CLI boundary is
  required.
- A privileged helper is rejected as unnecessary additional authority.

## Verification

Workstream 1 must pin the exact Xcode, Swift, and macOS SDK builds; compile a
release `arm64` artifact; inspect linked images, signatures, Hardened Runtime,
and entitlements; and test the sandbox and direct CLI configurations on clean
Apple Silicon Macs. Signing and notarization remain unverified until real
credentials and macOS infrastructure exist.

## Rollback Or Revisit Trigger

Revisit for an Intel release, App Store distribution, a changed minimum macOS,
an Apple bundle-identity conflict, or evidence that neither sandbox nor the
reviewed direct process boundary can run the official CLI safely.
