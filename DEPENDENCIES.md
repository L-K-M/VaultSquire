# Dependency Register

VaultSquire currently has no application dependencies. Workstream 0 records
candidates only; no package manifest or binary has been adopted.

Every future dependency must be recorded before adoption with:

| Field | Required information |
| --- | --- |
| Name | Package, framework, binary, tool, or data source |
| Purpose | Why standard Apple APIs or local code are insufficient |
| Exact version | Immutable version or commit |
| Origin | Canonical source and artifact URL |
| Integrity | Checksum, signature, or reproducible-build evidence |
| License | License and redistribution obligations |
| Transitives | Runtime/build dependency inventory |
| Security owner | Person responsible for advisories and upgrades |
| Update policy | Supported window and review cadence |
| Secret surface | Whether it handles keys, credentials, plaintext, network, or release assets |
| Removal plan | Migration or fallback if the dependency becomes unsafe |

## Candidate Register

| Candidate | Exact baseline | Origin and integrity | License/transitives | Owner and status |
|---|---|---|---|---|
| GRDB.swift | `7.11.1`; `b83108d10f42680d78f23fe4d4d80fc88dab3212` | [Release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1); archive SHA-256 `2beeb6962c1d5721707c0fae4bf803ee4d03b84202e16390eda10126fd213cb7` | MIT; no unconditional production package transitive | `L-K-M`; Workstream 5 spike only |
| SQLCipher.swift/XCFramework | `4.17.0`; `205df55271aa1ba512a9bfe3fd1813bc9ac52a19` | [Release](https://github.com/sqlcipher/SQLCipher.swift/releases/tag/4.17.0); binary SHA-256 `dd5a650346c1ba9933d6ba179f8844e03e4a075b3dd3a892796149864cd9ae57` | SQLCipher Community BSD-style terms; embeds SQLCipher Core/SQLite and uses Apple frameworks | `L-K-M`; Workstream 5 spike only |
| Canonical Argon2 | `f57e61e19229e23c4445b85494dbf7c07de721cb` | [Origin](https://github.com/P-H-C/phc-winner-argon2); archive SHA-256 `ac8c1d819a3b5da231b6549d79e02d0d41dc29469bd0dae94e775c62cb369e0a` | Select Apache-2.0 path; no package transitive | `L-K-M`; Workstream 3 spike only |
| KeyboardShortcuts | `3.0.1`; `49c3fc04ea827f816df67843bfcc57286b47ff06` | [Release](https://github.com/sindresorhus/KeyboardShortcuts/releases/tag/3.0.1); archive SHA-256 `bc5d48429e2ce247cbb9026433714e05ac153b2e212d12256800391dfc202956` | MIT; no declared package transitive | `L-K-M`; compare with Apple fallback in Workstream 1 |
| Sparkle | `2.9.4`; `b6496a74a087257ef5e6da1c5b29a447a60f5bd7` | [Release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4); SPM artifact SHA-256 `cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0` | MIT plus bundled notices; binary framework/helpers/XPC inventory | `L-K-M`; deferred until release hardening |

Detailed secret surfaces, known transitives, explicitly unresolved binary or
runtime components, update policies, removal plans, and blocking tests are
recorded in
[`docs/dependencies`](docs/dependencies/README.md). Every cryptography, storage
binary, updater, or release-pipeline adoption requires an independent second
reviewer.

## Platform Surface

The Apple registered-hot-key fallback is an OS/SDK surface, not a downloaded or
independently versioned dependency candidate. Workstream 1 must establish its
baseline by recording the exact Xcode, Swift compiler, and macOS SDK builds and
verifying the selected toolchain's Apple signature and provenance. Until then it
remains a comparison design, not an adopted API implementation. Its assessment
is recorded with
[`KeyboardShortcuts`](docs/dependencies/keyboard-shortcuts.md).

Proton's CLI is user-installed external software, not an application dependency.
It still requires exact executable identity/version command contracts before
use. Future features may propose additional candidates only through a register
and assessment update before their package manifest changes.
