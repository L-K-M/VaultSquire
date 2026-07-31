# Storage Candidate: GRDB And SQLCipher

- Status: preferred Workstream 5 spike; not adopted
- Owner: `L-K-M`
- Required second reviewer: storage security or supply-chain reviewer
- Research baseline: 2026-07-31

## Purpose

VaultSquire needs transactional migrations and snapshot publication while
encrypting SQLite pages, WAL data, journals, and temporary storage. System SQLite
alone is not an acceptable fallback.

## Candidate Identity

| Component | Exact identity | Integrity | License |
|---|---|---|---|
| GRDB.swift | `7.11.1`; commit `b83108d10f42680d78f23fe4d4d80fc88dab3212`; tree `ff52b3c22f4fc259de0adb63560b968cc4f0722a` | Commit archive SHA-256 `2beeb6962c1d5721707c0fae4bf803ee4d03b84202e16390eda10126fd213cb7`; no publisher signature/checksum | MIT |
| SQLCipher.swift | `4.17.0`; commit `205df55271aa1ba512a9bfe3fd1813bc9ac52a19`; tag object `c85425b80b8c9f0a1ceb4f72fa174e2b688181ba` | Source archive SHA-256 `1205d952b25d25e69ec2ae9734333d96a77cbf0fbad663eaf02aa20c322326c8` | SQLCipher Community BSD-style terms plus SQLite notices |
| SQLCipher XCFramework | `SQLCipher.xcframework.zip` from release `4.17.0` | Published SwiftPM SHA-256 `dd5a650346c1ba9933d6ba179f8844e03e4a075b3dd3a892796149864cd9ae57` | Same as SQLCipher.swift distribution |
| SQLCipher Core | `4.17.0`; commit `810db22f575ee7cf94ea96a3e91622b5fcece3dc` | Signed source ZIP SHA-256 `b09c6ac7b9b7e33786ab58987eb4d5b7a351064f89e2ccd7eafa78411de97d82`; signing fingerprint `D83F 5F9E B811 D6E6 B4A0 D9C5 D1FA 3A2A 97ED 25C2` | SQLCipher Community BSD-style terms |
| SQLite baseline | `3.53.3`; source ID `d4c0e51e4aeb96955b99185ab9cde75c339e2c29c3f3f12428d364a10d782c62` | Published amalgamation SHA3-256 `28e484abdaa43630e34040ef6ed92be973a1ad54107803d8af5145b889c23ed7` | Public domain |

Canonical origins and hashed artifacts:

- <https://github.com/groue/GRDB.swift/releases/tag/v7.11.1>
- <https://codeload.github.com/groue/GRDB.swift/tar.gz/b83108d10f42680d78f23fe4d4d80fc88dab3212>
- <https://github.com/sqlcipher/SQLCipher.swift/releases/tag/4.17.0>
- <https://codeload.github.com/sqlcipher/SQLCipher.swift/tar.gz/205df55271aa1ba512a9bfe3fd1813bc9ac52a19>
- <https://github.com/sqlcipher/SQLCipher.swift/releases/download/4.17.0/SQLCipher.xcframework.zip>
- <https://github.com/sqlcipher/sqlcipher/releases/tag/v4.17.0>
- <https://www.zetetic.net/downloads/sqlcipher/verify/4.17.0/sqlcipher-4.17.0.zip>
- <https://www.zetetic.net/downloads/sqlcipher/verify/4.17.0/sqlcipher-4.17.0.zip.sig>
- <https://www.zetetic.net/sqlcipher/verify>
- <https://www.sqlite.org/releaselog/3_53_3.html>
- <https://www.sqlite.org/2026/sqlite-amalgamation-3530300.zip>

The SQLCipher Core ZIP signature verified as good for the recorded fingerprint
at the research baseline. That authenticates bytes to the published key but does
not establish ultimate key trust or make a derived binary reproducible. The
GitHub tags/commits and XCFramework still lack accepted publisher provenance.

## Dependency Inventory

GRDB declares no unconditional remote production package dependency. The chosen
route requires a reviewed manifest adaptation so GRDB links the SQLCipher
product instead of system SQLite. SQLCipher.swift declares one binary target and
no remote package dependency. The XCFramework embeds SQLCipher Core and SQLite;
the Apple Community route uses OS Common Crypto, Foundation, Security, Swift
runtime, and Darwin libraries. Documentation tooling, tests, dSYMs, OpenSSL,
LibTomCrypt, CocoaPods, and system SQLite are excluded from the product graph.
Exact Mach-O load commands, extensions, compile options, and build inputs in the
XCFramework remain unknown and are explicitly blocking rather than omitted from
the transitive inventory.

## Redistribution Obligations

GRDB's complete MIT copyright, permission, and disclaimer text must accompany
source and binary distributions. SQLCipher.swift/Core BSD-style copyright,
conditions, and disclaimer must accompany source and binary distributions.
SQLite's public-domain provenance is recorded in the SBOM/notices even though it
does not require an open-source notice. Apple frameworks remain OS-supplied and
are governed by Apple SDK terms. Any build helper or newly discovered component
needs its own exact license record before use.

## Secret Surface

The stack runs in process and handles the random database key, decrypted pages,
row values, SQL arguments, migration state, and WAL/cache memory. Every
connection must be keyed before schema access and positively prove the expected
SQLCipher runtime. SQL text tracing, `cipher_log`, `cipher_profile`, plaintext
temporary databases, unkeyed fallback, and a second SQLite implementation are
prohibited.

## Blocking Spike

Workstream 5 must:

- create an immutable manifest-only GRDB adaptation and record its patch hash;
- pin the exact Xcode/SDK and verify the `arm64` slice, linked images, symbols,
  compile options, signatures, privacy manifest, and source-to-binary inventory;
- prove SQLCipher `4.17.0`, SQLite `3.53.3`, expected provider, active encryption,
  and no system SQLite linkage at runtime;
- decide raw-key/passphrase form and freeze page/KDF/HMAC/format settings;
- prohibit file-backed temp storage and scan main pages, WAL, journals,
  temporary files, migrations, backups, crashes, and logout artifacts for
  synthetic canaries;
- fault-inject key loss, wrong key, disk full, corruption, cancellation,
  process death, migration, checkpoint, and App Group access; and
- produce a complete SBOM, notices, and release-binary provenance.

The official XCFramework lacks a public SBOM, detached binary signature,
reproducible recipe, and source-to-binary attestation. If those gaps or binary
inspection fail, build an XCFramework from the signed SQLCipher Core source in a
separately reviewed reproducible pipeline.

## Update And Removal Policy

Review releases and advisories monthly and before every VaultSquire release; pin
one exact reviewed stack; never auto-merge. If GRDB becomes unacceptable,
replace only the Swift wrapper while preserving and cross-reading the encrypted
format. If SQLCipher must be replaced, copy through keyed live connections into
a separately encrypted candidate and publish atomically. If opening the old
library is unsafe, discard the reconstructible cache and rebuild from the
provider. Plaintext or system SQLite is never a fallback.
