# Workstream 5 Encrypted Persistence Record

- Status: the Swift-side storage-contract slice is implemented; the GRDB /
  SQLCipher engine adoption is deferred (see the scope boundaries below).
  Automated exit criteria run in the `macOS Product` lane via `scripts/ci.sh`;
  the merged PR's green run is the controlling evidence
- Owner: `L-K-M`
- Started: 2026-08-05
- Scope: the pure-Swift persistence seam — an `EncryptedStore` contract with
  atomic, monotonic snapshot publication; the versioned schema-migration
  registry; the device-only database-key contract; and the versioned generic
  cache-envelope AEAD — plus the in-memory and failing store doubles that let
  the contract's invariants be exercised without a storage engine.

This slice adds no dependency: the only cryptography is CryptoKit
(ChaCha20-Poly1305), an Apple system framework, so `DEPENDENCIES.md`'s "no
application dependencies" statement is unchanged. No network or database I/O is
performed and no real vault data is valid test input; every fixture is
synthetic `VSQ-Canary` material exercised with a test-only in-memory key.

## Scope boundaries for this slice

- **The GRDB / SQLCipher engine is deferred.** Adopting the binary storage
  stack is the second-reviewer-gated dependency PR described in
  [`docs/dependencies/storage.md`](docs/dependencies/storage.md) and governed by
  [ADR 0003](docs/adr/0003-dependency-adoption.md); `docs/dependencies/storage.md`
  records its status as "preferred Workstream 5 spike; not adopted." Its
  blocking checklist — an immutable manifest-only GRDB adaptation with a
  recorded patch hash, a pinned Xcode/SDK, `arm64` slice / symbol / signature /
  privacy-manifest verification, runtime proof of SQLCipher `4.17.0` and SQLite
  `3.53.3` with no system-SQLite linkage, a frozen page/KDF/HMAC/format, and a
  complete SBOM, notices, and release-binary provenance — is binary and toolchain
  work, not Swift-contract work, and is intentionally out of this slice. The
  `EncryptedStore`, `MigrationRegistry`, and `DatabaseKey` types are the seams
  that adoption satisfies without changing callers.
- **On-disk evidence is owed to the engine spike.** PLAN.md's Workstream 5 exit
  criteria "no fixture plaintext in the database, WAL, journals, temporary
  files, preferences, or state restoration" and "process death at every commit
  stage yields either the prior or complete new generation" are properties of
  the real SQLCipher database on disk. This slice proves the engine-independent
  form of each — generation atomicity and monotonicity, the logout-wipe
  post-condition, and no-plaintext-at-rest for the application AEAD — and the
  literal filesystem, WAL, and process-death evidence is gathered on the storage
  spike, exactly as Workstream 4 left its pinned-container and private-CA lanes
  owed while merging its Swift slice.
- **Offline unlock and vault display are later workstreams.** Wiring a real
  database key into the Keychain, hydrating the in-memory projection from stored
  ciphertext, offline master-password unlock, and stale-snapshot presentation
  are Workstreams 5 (engine)–7. This slice defines only the at-rest contract they
  build on.

## Implemented Surface

`VaultSquire/Persistence/`:

- **Store contract** (`EncryptedStore`, `AccountSnapshot`, `EncryptedRecordRow`,
  `StoreIntegrity`, `EncryptedStoreError`). The at-rest seam for one
  installation's encrypted account data (ARCHITECTURE `EncryptedStore`). It
  persists provider-native ciphertext rows, opaque provider sync state, cache
  envelopes, the durable reauthentication marker, and the AEAD-wrapped
  quick-unlock user key, and commits the snapshot generation and its date in the
  same transaction as the data they describe. `publish(_:)` is whole-snapshot and
  atomic: it either makes the offered generation current or leaves the prior one
  intact, and it rejects a generation that does not strictly advance the current
  one. Records are read back in a deterministic, non-secret order (revision date,
  then item identifier) so a locked snapshot hydrates without decrypting
  anything. The contract forbids storing a decrypted name, username, URI, note,
  or search term.
- **Schema migrations** (`SchemaVersion`, `SchemaMigration`, `MigrationRegistry`,
  `MigrationRegistryError`). An ordered registry that validates its migrations
  form a strictly increasing, gap-free sequence from version 1, computes the
  pending tail for a database at a given installed version, and rejects a
  database written by a newer build rather than downgrading it. The order is a
  reviewed, engine-independent fact; the real store applies the pending
  migrations transactionally on open.
- **Database key** (`DatabaseKey`). The device-only raw database-key value type:
  fixed 32-byte width with rejection of any other width, and CSPRNG generation.
  It documents the keyed-before-schema-access and same-at-rest-protection
  requirement (pages, WAL, journals, temporary files) that the deferred engine
  must honor, and gives the raw key a single typed home instead of bare `Data`.
- **Cache-envelope AEAD** (`CacheEnvelopeCipher`, `CacheEnvelopeContext`,
  `CacheEnvelopeCipherError`). The versioned generic AEAD that wraps a provider's
  lossy, decrypted payload (for example Proton CLI JSON) into the
  `lossyApplicationEncrypted` bytes a `ProviderCacheEnvelope` carries. It binds
  each sealed payload to its account, provider, and envelope schema version as
  authenticated data, uses a random per-message nonce, and fails closed on a
  wrong key, tampered bytes, or a mismatched context. Provider-native ciphertext
  is never wrapped by it — that rests as its own lossless bytes — so the lossy
  blob boundary stays explicit.

`VaultSquireTests/` adds the in-memory `EncryptedStore` (mirroring the atomic,
monotonic, order-preserving, wipe-clean semantics), a failing store for the
store-unavailable path, and the contract, migration, and AEAD suites. No logging
event is added, so the fixed-enum allowlist and `DiagnosticsTests` are unchanged
and the leakage requirement holds by construction.

## Exit Criteria

| Criterion | Evidence |
|---|---|
| A snapshot publishes whole or not at all; a failed or cancelled publish leaves the prior generation intact (no mixed generation) | `EncryptedStoreTests.testFailedPublishLeavesPriorGenerationIntact`, `.testCancelledPublishWritesNothing` |
| The snapshot generation strictly advances and is committed with its date | `EncryptedStoreTests.testGenerationMustStrictlyAdvance`, `.testSnapshotDateCommittedWithGeneration` |
| Records are hydrated in deterministic, non-secret order without decryption | `EncryptedStoreTests.testRecordsReturnedInRevisionThenIdentifierOrder` |
| The lossy provider blob stays separable from native ciphertext rows | `EncryptedStoreTests.testCacheEnvelopeRoundTripsAndStaysSeparableFromRecords` |
| A rotation can require reauthentication while retaining the prior snapshot | `EncryptedStoreTests.testReauthenticationMarkerPersistsWithoutDisturbingSnapshot` |
| Logout leaves no account credential, cache key, or snapshot behind | `EncryptedStoreTests.testWipeRemovesEveryTraceOfTheAccount` |
| Corruption and store-unavailability surface as typed failures | `EncryptedStoreTests.testIntegrityReportsForcedCorruption`, `.testFailingStoreReportsUnavailable` |
| Migrations form a validated ordered sequence; only the pending tail applies; a newer-build database is rejected | `MigrationRegistryTests` (fresh / up-to-date / partial / malformed / newer-build cases) |
| The application AEAD round-trips and fails closed on wrong key, tampering, or a mismatched account/provider/schema-version context | `CacheEnvelopeCipherTests` seal/open, wrong-key, tamper, and mismatch cases |
| A wrapped payload never rests in the clear | `CacheEnvelopeCipherTests.testSealedOutputContainsNoPlaintext` |
| The device-only database key is full-width and CSPRNG-generated | `CacheEnvelopeCipherTests.testDatabaseKeyGeneratesDistinctFullWidthKeys`, `.testDatabaseKeyRejectsWrongWidth` |

The `EncryptedStore` invariants are proved against the in-memory store, which
mirrors the real store's atomic, monotonic, order-preserving, and wipe-clean
semantics. The on-disk realization of the no-plaintext and process-death
criteria — SQLCipher page/WAL/journal/temp encryption and torn-write behavior on
real hardware — is gathered on the storage spike named in the scope boundaries,
per `docs/dependencies/storage.md` and SECURITY_AND_TESTING.md, and is not this
PR's evidence.

## Outstanding Workstream 1 Exit Evidence

This slice consumes no outstanding Workstream 1 evidence. Per
[ADR 0006](docs/adr/0006-workstream-1-merge-with-outstanding-evidence.md) and
[`WORKSTREAM_1.md`](WORKSTREAM_1.md), these rows remain owed, block Phase 0
certification and any release, and are restated here unchanged:

- Cold launch p95 at or below 750 ms on named baseline hardware.
- Warm Quick Search p95 at or below 100 ms on named baseline hardware.
- Keyboard focus and Escape dismissal manual confirmation.
- VoiceOver and Full Keyboard Access interactive test.
- Multiple Spaces and full-screen auxiliary presentation interactive test.
- Direct versus sandbox executable launch behavior on a disposable account.
- Direct versus sandbox session and keyring behavior (not implemented; blocks
  Workstream 10).
- Security-scoped bookmark round trip across launches (not implemented; blocks
  Workstream 10).
- Executable code signature and notarization status recorded at approval (not
  implemented; blocks Workstream 10).
- Generated 16/32/64 px icon review (blocked by `ICON_PROVENANCE.md`).

The Phase 0 storage proof additionally owes the GRDB / SQLCipher engine adoption
and its on-disk encryption, canary, fault-injection, and provenance evidence
named in the scope boundaries above. Presence in `main` is not evidence that a
criterion passed; a row is marked passed only when the evidence exists.
