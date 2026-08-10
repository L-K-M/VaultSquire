# VaultSquire

VaultSquire is a native macOS client for self-hosted Vaultwarden instances and
Proton Pass accounts. The Vaultwarden provider is implemented end to end —
sign-in with an optional second factor, master-password unlock, sync, a
device-sealed encrypted offline cache, item browsing with reveal, copy, and
rotating TOTP, and create, edit, and archive writes. The Proton Pass provider is
implemented read-only through the official user-installed CLI: detection, a
fail-closed version gate, vault and item reads, and a device-sealed lossy
offline snapshot. There is no supported or distributable release; release
automation stays blocked by [`RELEASE_ELIGIBILITY.md`](RELEASE_ELIGIBILITY.md).

Current source version: <!-- version -->0.1.0<!-- /version -->. This is a source
version, not a supported or distributable release.

> LLM Disclosure: VaultSquire's research and planning documents are being
> developed with substantial assistance from large language models (AI coding
> and research tools). Their output is reviewed against primary and immutable
> sources; automated review does not replace human security or provenance review.

## Implementation Context

This is the accepted clean-history implementation repository exported from the
approved planning tree. The source-isolation attestation applies to root commit
`81cfb67df4ab7e06bdd1961ef98168b6dcf1ca9c` and reviewed descendants. Workstream
0 governance is recorded, and Workstreams 1 through 3 are merged with the exit
evidence each of their records still lists as outstanding.
See
[`IMPLEMENTATION_CONTEXT.md`](IMPLEMENTATION_CONTEXT.md) for the exact source
tree, isolation procedure, exclusions, and completed reviewer attestation.

The intended product is small, fast, local-first, and explicit about its
security boundaries:

- one clean-room native Swift application named VaultSquire;
- one add-account sheet whose provider choice lists Vaultwarden (a form for
  server URL, email, and master password, followed by a second-factor step only
  when the server requires one) and Proton Pass (a credential-free detection
  pane that connects to your own signed-in official CLI and opens the vault
  read-only);
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

## Implementation Status

- **Vaultwarden — read and write.** Origin-approved sign-in with optional
  second factor, PBKDF2/HKDF key derivation and EncString decryption, sync into
  a ChaCha20-Poly1305 device-sealed cache, master-password unlock, item list and
  detail with reveal, clipboard, and RFC 6238 TOTP, and create, edit, and
  archive writes gated per capability. Argon2id KDF fails closed.
- **Proton Pass — read only, through your own CLI.** VaultSquire never asks for
  a Proton credential; sign-in stays with the official user-installed CLI. The
  provider locates an allowlisted absolute binary path (symlink resolved and
  shown), runs it with no shell, a fixed environment (`HOME` passed through, not
  relocated), standard input bound to the null device, and bounded output, and
  gates the reported version against a fail-closed allowlist. It lists vaults and
  items, hydrates item content, projects items into the shared read UI, and seals
  a lossy snapshot with the same AEAD envelope for offline read. No write, argv
  secret, or environment secret is ever produced.
- **Caveat.** The Proton CLI command and JSON contract is implemented against
  Proton's *documented* surface (PROTON_PASS_RESEARCH.md §5, §8) and gated to the
  releases recorded there; it has not been exercised against a live CLI in this
  environment. On a real machine the version allowlist and the JSON key mapping
  are the single points to reconcile against the installed build — a mismatch
  fails closed with an honest "couldn't read the CLI output", never a false
  success. All CLI-boundary logic is covered by unit tests over a fake executor.
- **No release.** Release, preview, and distribution remain blocked by
  [`RELEASE_ELIGIBILITY.md`](RELEASE_ELIGIBILITY.md); this is a source tree, not
  a shippable product.

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
8. [`WORKSTREAM_0.md`](WORKSTREAM_0.md): governance/evidence completion record
   and deferred gates.
9. [`DEPENDENCIES.md`](DEPENDENCIES.md): candidate inventory and adoption policy.
10. [`EVIDENCE.md`](EVIDENCE.md): immutable protocol/container research pins.
11. [`ICON_PROVENANCE.md`](ICON_PROVENANCE.md): canonical artwork attestation and
    technical review.
12. [`DELIVERY.md`](DELIVERY.md): sequential pull-request milestones.
13. [`WORKSTREAM_1.md`](WORKSTREAM_1.md): native shell implementation and
    outstanding macOS evidence gates.
14. [`WORKSTREAM_2.md`](WORKSTREAM_2.md): domain, session, and provider contracts
    proven against a test-only provider facade.
15. [`WORKSTREAM_3.md`](WORKSTREAM_3.md): Vaultwarden cryptographic harness and
    the cross-client differential still owed.
16. [`WORKSTREAM_4.md`](WORKSTREAM_4.md): environment, transport, authentication,
    the add-account UI, and Keychain credential storage.
17. [`WORKSTREAM_5.md`](WORKSTREAM_5.md): the encrypted-persistence contract slice
    with the storage engine deferred.
18. [`docs/adr/README.md`](docs/adr/README.md): accepted architecture decisions.
19. [`CICD.md`](CICD.md): local build/version commands and guarded future release
    automation.
20. [`RELEASE_ELIGIBILITY.md`](RELEASE_ELIGIBILITY.md): evidence required before
    that automation may be enabled.

If documents appear to conflict, `PLAN.md` controls product scope and sequence,
`SECURITY_AND_TESTING.md` controls security invariants and release gates, and
`ARCHITECTURE.md` controls component/data boundaries. A
conflict among those three blocks implementation until the documents are
reconciled; do not silently choose the less restrictive rule.
`IMPLEMENTATION_REPORT.md` and the Proton report are subordinate evidence. The
Keyguard decision is a binding rejection, source-isolation, and preimplementation
history-isolation gate.

## Build And Verification

The project is pinned to Xcode 26.6 on native Apple Silicon. On a matching Mac,
run `./scripts/ci.sh` for unit/UI tests plus direct and sandbox-feasibility
artifacts. Run `./scripts/measure-workstream-1.sh` separately to exercise the
launch and Quick Search performance fixtures; that lane detects crashes and
hangs, and the hosted runner has so far exported no machine-readable metrics
from it, so it is not evidence that a performance budget was met.
Repository-only checks remain portable through `./scripts/check-repository.sh`.

`./scripts/build.sh` is the family-standard local entry point and preserves the
three reviewed product modes in `build-local.sh`. `./scripts/build.sh --check`
prints its resolved contract, including the resolved signing team, without
requiring macOS. A development-signed local installation uses
`./scripts/build.sh --install`; it signs with the Apple Developer Team ID
recorded in the Xcode project, and `DEVELOPMENT_TEAM=XXXXXXXXXX` overrides that
for a contributor signing with a different Apple Developer account. An ad-hoc
artifact cannot validate App Group provisioning, which is why this path needs a
real team.

`./scripts/release.sh --check` reports the version and release gate. Actual
release execution is deliberately blocked in both the script and GitHub Actions
while `.github/release-eligibility.env` is false. See [`CICD.md`](CICD.md).

The app-icon catalog is derived from the attested source by
`scripts/generate-app-icon.py` and recorded in `ICON_PROVENANCE.md`, whose
small-size visual review remains open. No application package dependency has
been adopted.

## Research Baseline

Research was performed on 2026-07-31. Source claims use pinned repository
revisions wherever possible. Vaultwarden and both upstream client protocols are
moving targets, so implementation must revalidate every pinned assumption
before release.

No affiliation with or endorsement by Vaultwarden, Bitwarden, Keyguard, or
Proton is implied.
