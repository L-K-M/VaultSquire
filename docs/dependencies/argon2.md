# Cryptography Candidate: Argon2id

- Status: preferred Workstream 3 packaging spike; not adopted
- Owner: `L-K-M`
- Required second reviewers: two independent cryptography/supply-chain reviewers
- Research baseline: 2026-07-31

## Purpose

Vaultwarden Argon2id accounts require arbitrary valid iteration, memory, and
parallelism parameters. Apple platform cryptography does not provide this
primitive. No reviewed candidate currently proves prompt cancellation and
universal resource cleanup, so adoption remains blocked.

## Preferred Candidate

| Field | Value |
|---|---|
| Origin | <https://github.com/P-H-C/phc-winner-argon2> |
| Exact revision | `f57e61e19229e23c4445b85494dbf7c07de721cb` |
| Commit archive | <https://github.com/P-H-C/phc-winner-argon2/archive/f57e61e19229e23c4445b85494dbf7c07de721cb.tar.gz> |
| Archive SHA-256 | `ac8c1d819a3b5da231b6549d79e02d0d41dc29469bd0dae94e775c62cb369e0a` |
| Package form | Swift tools 5.3 C library target; no declared package transitives or bundled binary |
| Selected license path | Apache License 2.0 from the upstream Apache-2.0/CC0 choice |
| Maintenance | Selected/default revision dates to 2021; latest release dates to 2019 |
| Signature | No verified signature or publisher checksum for the selected revision |

The candidate receives exact master-password bytes, a 32-byte SHA-256 email
salt, validated parameters, and a 32-byte output buffer. It has no documented
hard-cancellation hook. Caller and native buffers, matrix memory, worker threads,
and late output are security-sensitive. The final C runtime, threading linkage,
compiled objects, and exported symbols are not yet inventoried and remain an
explicit adoption blocker.

## Secondary Comparator

`dugleelabs/swift-argon2` `1.0.0`, commit
`3ff9845312fda8fd1fa2f436761152cc207b3575`, archive SHA-256
`f31d02c3e3dfedafe52f347405ee54f5bfb0384bc57cfe67ce44881040f21318`,
is an Apache-2.0 Swift wrapper over a claimed copy of the preferred canonical
revision. It has no external package transitives but is a one-release project,
has no verified release signature/SBOM/provenance, and does not solve hard
cancellation. Its vendoring claim must be independently verified before use.

- Origin: <https://github.com/dugleelabs/swift-argon2/releases/tag/1.0.0>
- Hashed artifact:
  <https://github.com/dugleelabs/swift-argon2/archive/refs/tags/1.0.0.tar.gz>
- Purpose: compare a prepackaged Swift wrapper against the direct canonical C
  package if the preferred packaging spike fails.
- Owner, update, secret-surface, and removal policies are the same as the
  preferred candidate; it cannot be selected without a complete independent
  assessment update.

## Screened Alternatives, Not Candidates

- `mimiclone/argon2-swift` requires macOS 15 and lacks mature audit evidence.
- `swift-sodium` does not expose arbitrary Argon2 parallelism and is broader than
  needed.
- `tmthecoder/Argon2Swift` resolves a mutable upstream `master` dependency.
- `argon2id-swift-native` is an unaudited, very small new primitive project.

Because these alternatives are rejected rather than current candidates, they do
not enter the dependency register. Reconsidering one requires a new complete
identity, integrity, license, transitive, owner, update, secret-surface, and
removal assessment.

If the Apache License 2.0 path is adopted for canonical Argon2, VaultSquire must
include the license, retain applicable attribution/NOTICE material, and mark
local modifications as required. The Duglee wrapper's Apache-2.0 license and the
vendored primitive's selected license path require separate notices.

## Required Contract And Spike

- Argon2id version `0x13`; exact UTF-8 password bytes; SHA-256 normalized-email
  salt; output exactly 32 bytes.
- Validate iterations 2-10, memory 16-1024 MiB with checked MiB-to-KiB
  conversion, and parallelism 1-16 before allocation.
- Build optimized native `arm64` under the pinned Workstream 1 toolchain and
  inventory every linked object and symbol.
- Pass RFC 9106 plus independently generated synthetic differential vectors for
  boundary and mixed parameter combinations with no retry.
- Prove leading/trailing whitespace, multibyte UTF-8, and embedded NUL are not
  normalized or truncated.
- Measure wall time, CPU, peak memory, worker count, cleanup latency, allocation
  failure, and app-wide maximum-KDF serialization.
- Cancel before allocation and at measured early/middle/late execution points;
  lock must invalidate the session generation before cancellation. Native work
  must terminate within a separately reviewed deadline, not merely discard its
  eventual output.
- Scan logs, crash output, temporary files, test artifacts, preferences, and
  diagnostics for unique password/salt/output canaries.
- Complete source audit, notices, SBOM, archive/tree verification, and two-person
  review in the isolated implementation context.

## Update And Removal Policy

Review the exact revision, generic Argon2 advisories, wrappers, compiler, and
platform monthly and before releases. Hide the implementation behind one
VaultSquire-owned Argon2id-v1.3 operation. A replacement must produce
byte-identical output for the complete matrix. Provider KDF settings and
ciphertext remain unchanged, so no persisted-data migration is expected. If no
safe implementation exists, preserve ciphertext and fail closed for Argon2id
accounts; never substitute PBKDF2 or weaker parameters.
