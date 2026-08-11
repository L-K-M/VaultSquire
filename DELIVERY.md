# Pull Request Delivery Sequence

`PLAN.md` controls scope and workstream order. This file records how that order
maps to reviewable pull requests; it does not weaken any exit criterion.

| Order | Pull request milestone | Merge condition |
|---:|---|---|
| 0A | History-isolated root and attestation | Merged as PR #2; exact root and reviewer recorded |
| 0B | Workstream 0 governance and evidence | Merged as PR #3; ADRs, evidence/dependency registers, fixture policy, license, icon provenance, and local hygiene pass |
| 1 | Native shell and performance harness | Merged as PR #5 with exit criteria outstanding, by the decision in [ADR 0006](docs/adr/0006-workstream-1-merge-with-outstanding-evidence.md); the criteria are still owed and now gate release rather than merge |
| 2 | Domain, session, and provider contracts | Merged as PR #9; Workstream 2 race/capability/identity tests pass |
| 3 | Vaultwarden crypto harness | Merged as PR #10 with the pinned-container cross-client differential outstanding; Workstream 3 vectors, malformed cases, bounds, cancellation, and fuzz gates pass, and the differential is release evidence recorded in [`WORKSTREAM_3.md`](WORKSTREAM_3.md) |
| 4 | Environment, transport, authentication, and 2FA | Workstream 4 contract/leakage matrix passes |
| 5 | Encrypted persistence and offline unlock | Workstream 5 storage, Keychain, corruption, migration, and process-death gates pass |
| 6 | Vaultwarden sync, decryption, and read models | Workstream 6 aggregate-sync, tolerant-decoding, organization, and permission gates pass |
| 7 | Vault UI, search, clipboard, and URI handling | Workstream 7 accessibility, leakage, and release-performance gates pass |
| 8A | Security hardening and signed candidate infrastructure | Pre-artifact hardening and candidate gates pass; reviewed infrastructure may merge while distribution remains blocked |
| 8B | Private preview qualification | The protected workflow produces one restricted draft candidate; artifact-dependent stop-ship, signing, notarization, support, and clean-Mac evidence passes before any distribution |
| 9 | Safe Vaultwarden core writes | Workstream 9 cross-client, conflict, ambiguity, and unknown-field gates pass |
| 10A | Proton process boundary and read provider | Workstream 10 read, cache, process, sandbox/direct, and leakage gates pass |
| 10B+ | One PR per safe Proton write operation | Exact command/version protected-input and reconciliation gates pass |
| 10C | 1Password process boundary and read provider | Fake-executor read, cache, account-scoping, version-gate, and leakage gates pass; the terms question and the TTY-less authorization/sandbox spike in [`ONEPASSWORD_CLI_RESEARCH.md`](ONEPASSWORD_CLI_RESEARCH.md) §1 remain outstanding and gate release, not merge, by [ADR 0007](docs/adr/0007-onepassword-third-provider.md) |
| 11+ | One PR per advanced feature | Separate threat model and feature-specific phase gate passes |

Each PR is opened only after its predecessor merges. It waits for GitHub review
or check failure, addresses all actionable feedback, and merges only at steady
state. Security, provenance, licensing, contamination, or secret-bearing diffs
must not receive the external `glm-review` label.

## Current Infrastructure

The account can allocate GitHub-hosted Apple Silicon `macos-26` jobs and the
Workstream 1 workflow pins Xcode 26.6. Hosted CI can compile AppKit/SwiftUI, run
automated tests, create ad-hoc Hardened Runtime artifacts, and inspect binaries
and entitlements through the same scripts used locally.

Hosted automation does not satisfy interactive VoiceOver, Full Keyboard Access,
multiple-Spaces/full-screen focus, Developer ID/notarization, small-size icon,
or real Proton CLI session/keyring checks. Those measurements and manual results
are still owed on a named Apple Silicon Mac. They no longer block the
Workstream 1 merge, which has happened, but they do block any release or
distributed artifact; see
[ADR 0006](docs/adr/0006-workstream-1-merge-with-outstanding-evidence.md) and the
Exit Evidence table in [`WORKSTREAM_1.md`](WORKSTREAM_1.md).

The repository contains a signed-only future release workflow so that signing,
provisioning, notarization, final-package inspection, checksums, and
provenance behavior are reviewable before credentials exist. It is not active:
`.github/release-eligibility.env` and a matching approval marker in the recorded
gate must both enable it. Until then the workflow exits before credentials or
artifacts, as documented in [`CICD.md`](CICD.md).
