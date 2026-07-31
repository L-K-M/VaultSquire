# Updater Candidate: Sparkle 2

- Status: deferred release-hardening candidate; not adopted
- Owner: `L-K-M`
- Required second reviewer: independent release/supply-chain reviewer
- Research baseline: 2026-07-31

## Candidate Identity

Sparkle is considered because secure app replacement, relaunch, signed-feed
handling, rollback behavior, and helper coordination are high-risk to recreate
with ad hoc application code. Manual signed/notarized downloads remain the
preferred no-dependency path until the full updater threat model passes.

| Field | Value |
|---|---|
| Exact release | `2.9.4`; commit `b6496a74a087257ef5e6da1c5b29a447a60f5bd7`; tree `7ffae2641e3af744b26d0b0cb07ad179256fc439` |
| Origin | <https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4> |
| SPM artifact | `Sparkle-for-Swift-Package-Manager.zip`; SHA-256 `cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0` |
| Full release | `Sparkle-2.9.4.tar.xz`; SHA-256 `ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9` |
| License | MIT plus bundled BSD-2-Clause, MIT, and zlib-style notices |
| Declared packages | No remote Swift package dependency; one binary target |
| Architectures | Artifact advertises `arm64` and `x86_64`; VaultSquire initially ships `arm64` only |
| Integrity limits | Lightweight unsigned tag/commit, mutable release, no detached signature or source-to-binary attestation |

Hashed artifacts:

- <https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip>
- <https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-2.9.4.tar.xz>

The artifact includes an in-process framework, updater/helper executables, XPC
services, localization/resources, and build-side signing/appcast tools. Package
dependency count is not a complete SBOM. Legacy DSA tools, deltas, package
installers, unused XPC services, dSYMs, and helper tools are excluded from the
initial shipping design.

Binary distributions must reproduce Sparkle's MIT notice and every bundled
BSD-2-Clause, MIT, and zlib-style attribution identified by the pinned license
file. Newly discovered components block adoption until their terms and notices
are added.

## Required VaultSquire Policy

- Manual signed/notarized downloads remain the only beta update path.
- Re-pin the then-current stable release before adoption.
- Use a fixed HTTPS feed, signed feed metadata/release notes/full archives,
  pre-extraction verification, and zero signed-feed failure expiration.
- Disable automatic installation, system profiling, JavaScript, custom URL
  schemes, custom feed parameters, deltas, and package installers initially.
- Keep Ed25519, Developer ID, notarization, hosting, and checksum credentials
  separately scoped and outside source, argv, logs, ordinary CI, and artifacts.
- Recursively re-sign and inspect every nested executable with VaultSquire's
  Developer ID and verify Hardened Runtime, entitlements, notarization, and
  stapling.

## Blocking Risks

The prebuilt sandbox path documents a temporary Mach-service exception that
conflicts with VaultSquire's default entitlement policy. Adoption waits for the
sandbox/direct distribution ADR result. Public CVE-2026-47121 and
CVE-2026-47122 metadata must be reconciled against the selected release; no
affected or ambiguously remediated version may ship. The binary needs a complete
Mach-O, helper, license, SBOM, signature, and provenance audit.

## Update And Removal Policy

Monitor stable releases and advisories weekly and before release candidates.
Support one exact reviewed patch, never auto-merge. Keep Sparkle behind an
app-owned update coordinator and preserve manual downloads as an emergency
fallback. Feed or signing-key compromise disables the feed; if safe key rotation
cannot be proven, distribute an independently checksummed notarized replacement
manually. Test upgrades to a removal build before deleting framework, helpers,
XPC services, preferences, and entitlements.
