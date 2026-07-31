# VaultSquire

VaultSquire is a planned, completely new native macOS client for self-hosted
Vaultwarden instances and Proton Pass accounts. The project is currently in the
research and design stage. There is no application implementation yet.

> LLM Disclosure: VaultSquire's research and planning documents are being
> developed with substantial assistance from large language models (AI coding
> and research tools). Their output is reviewed against primary and immutable
> sources; automated review does not replace human security or provenance review.

## Implementation Context

This is the accepted clean-history implementation repository exported from the
approved planning tree. The source-isolation attestation applies to root commit
`81cfb67df4ab7e06bdd1961ef98168b6dcf1ca9c` and reviewed descendants. Workstream
0 governance is still in progress, so the repository contains no application
code or build scaffolding. See
[`IMPLEMENTATION_CONTEXT.md`](IMPLEMENTATION_CONTEXT.md) for the exact source
tree, isolation procedure, exclusions, and completed reviewer attestation.

The intended product is small, fast, local-first, and explicit about its
security boundaries:

- one clean-room native Swift application named VaultSquire;
- one Vaultwarden add-account form for server URL, email, and master password,
  followed by a second-factor step only when the server requires one;
- Proton Pass access through the official user-installed CLI, with required
  reads and writes enabled only per exact tested command/version when complete
  private input uses a protected non-argv, non-environment, non-filesystem
  channel;
- Vaultwarden-native ciphertext and VaultSquire-AEAD-wrapped lossy Proton
  snapshots for encrypted offline access;
- fast launch, keyboard-first navigation, and fast local search;
- browsing, creating, and archiving entries, enabled per provider only where the
  provider actually supports the operation: Vaultwarden 1.37.1 has per-user
  cipher archiving, and the researched Proton CLI documentation exposes no
  archive command, so that action remains disabled there rather than mapped onto
  trash or deletion unless a tested future command contract supports it;
- no plaintext vault database, default telemetry, or TLS bypass;
- provider boundaries that support Vaultwarden and the Proton CLI without
  pretending that the two services share one protocol or cryptographic model.

## Current Recommendation

Build VaultSquire independently as a native macOS application. The Keyguard fork
path is permanently rejected because its license does not grant the rights this
project needs. No Keyguard code, structure, tests, strings, assets, or detailed
implementation design may be copied or adapted. Only vague product-level
inspiration from normal use is permitted.

Proton Pass is a planned second provider through the official CLI. VaultSquire
will not reimplement Proton's private API or copy, link, or bundle Proton client
code. Read access is required. Create, update, delete, and other write
capabilities are enabled per exact tested command and CLI version only when
complete private input avoids process arguments, environment variables, logs,
and every plaintext file. CLI JSON is lossy decrypted output: VaultSquire wraps
it with AEAD before persistence, never uses it to synthesize writes, and
terminates CLI work on lock. App Sandbox is retained only if the CLI boundary
works safely; otherwise the reviewed direct Developer ID Hardened Runtime build
is used.

The canonical product icon source is [`media-sources/icon.png`](media-sources/icon.png).
Generated macOS icon assets must derive from that file without replacing it.

## Documentation

Read the documents in this order:

1. [`PLAN.md`](PLAN.md): product definition, decisions, scope, work breakdown,
   and phase exit criteria.
2. [`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md): threat model,
   verification strategy, release gates, and secure development requirements.
3. [`ARCHITECTURE.md`](ARCHITECTURE.md): normative native macOS component,
   state, storage, and provider boundaries.
4. [`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md): pinned Vaultwarden
   endpoint, authentication, cryptographic, sync, and compatibility research.
5. [`KEYGUARD_FORK_ASSESSMENT.md`](KEYGUARD_FORK_ASSESSMENT.md): rejected fork
   decision and mandatory source-isolation rules.
6. [`PROTON_PASS_RESEARCH.md`](PROTON_PASS_RESEARCH.md): selected CLI
   integration, read/write capability rules, data model, and risks.
7. [`IMPLEMENTATION_CONTEXT.md`](IMPLEMENTATION_CONTEXT.md): clean-history
   bootstrap procedure and attestation status.

If documents appear to conflict, `PLAN.md` controls product scope and sequence,
`SECURITY_AND_TESTING.md` controls security invariants and release gates, and
`ARCHITECTURE.md` controls component/data boundaries. A
conflict among those three blocks implementation until the documents are
reconciled; do not silently choose the less restrictive rule.
`IMPLEMENTATION_REPORT.md` and the Proton report are subordinate evidence. The
Keyguard decision is a binding rejection, source-isolation, and preimplementation
history-isolation gate.

## Research Baseline

Research was performed on 2026-07-31. Source claims use pinned repository
revisions wherever possible. Vaultwarden and both upstream client protocols are
moving targets, so implementation must revalidate every pinned assumption
before release.

No affiliation with or endorsement by Vaultwarden, Bitwarden, Keyguard, or
Proton is implied.
