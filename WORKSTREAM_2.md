# Workstream 2 Domain, Session, And Provider Contracts Record

- Status: implemented; automated exit criteria run in PR #9's `macOS Product`
  lane, first green in workflow run `31014810704`, and the merged PR's final
  green run is the controlling evidence
- Owner: `L-K-M`
- Started: 2026-08-05
- Scope: domain identities, orthogonal session state, capability gating, cache
  envelope and projection contracts, and one fake provider facade only

Workstream 2 does not implement a production provider, cryptography, network
transport, persistence, Keychain access, or any user-visible change. The
application UI remains locked-only; the fake provider facade lives in the unit
test target and never ships. No real vault or account data is valid test input.

## Implemented Surface

- Compound identities namespaced by provider, account, provider space/share,
  and item (`ProviderID`, `AccountID`, `VaultSpaceID`, `VaultItemID`). The
  personal scope is modeled explicitly rather than reserving a magic provider
  identifier, so a provider space literally named `personal` cannot collide.
- Orthogonal session state with four coordinated dimensions (account, vault
  access, connectivity, sync operation) and serialized transitions inside the
  `VaultSession` actor. There is no single enum of every combination.
- Two deliberately distinct generation types. `SessionGeneration` discards
  late plaintext results and exists only while unlocked or unlocking; it is
  neither `Comparable` nor `Codable`. `SnapshotGeneration` identifies the
  current committed encrypted snapshot, is ordered for monotonic checks, and
  survives lock. They cannot be conflated at compile time.
- `VaultSession` invalidates the session generation before cancelling
  registered work on lock, discards any completion or publication carrying a
  stale generation, and clears decrypted projections on every lock. A
  cancelled reauthentication returns to `reauthenticationRequired` without
  touching cached state; `reauthenticationRequired` still permits cache
  unlock because reauthentication gates remote access, not the local cache.
- Exact per-action capability values and one `CapabilityGate` use-case
  boundary. Provider mutations require a `CapabilityAuthorization` that only
  the gate can create, so no entry point — menu, keyboard shortcut, context
  menu, deep link, or accessibility action — can bypass a capability check.
  Structural gate authorization covers mutations now; read actions (reveal,
  copy, search) gain their gate-issued authorizations with the Workstream 7
  UI, where those action paths first exist.
- Two separate cancellation registries with different lifetimes: registered
  plaintext-producing work is cancelled by every lock, while registered sync
  work survives a plain lock — ciphertext-only sync may continue while
  locked — and is cancelled by logout, which also resets the sync dimension,
  because logout cancels all sync.
- Provider cache-envelope contract with explicit fidelity metadata
  (lossless native ciphertext versus lossy application-encrypted), schema
  version, capture snapshot generation, and an opaque payload preserved byte
  for byte. Opaque provider sync state with no cross-provider interpretation.
- A narrow immutable `Sendable` display projection (title, subtitle, canonical
  category with an explicit unsupported case, username, websites, non-secret
  grouping labels, capabilities, and a stable cache reference).
- One fake provider facade in the unit test target implementing the single
  compiled `VaultProvider` facade (ADR 0002) across its session, catalog,
  records, sync, capabilities, and cache-envelope seams, with controllable
  suspension for lock-race tests and mutation recording for gate tests.

The envelope contract performs no cryptography; the AEAD arrives with
Workstream 5 and the envelope payload is already-protected bytes by contract.
The envelope types deliberately do not adopt `Codable`: their at-rest
serialization is the Workstream 5 persistence schema's decision, and an early
synthesized encoding would become an accidental format commitment.
No new logging events are added, so the fixed-enum allowlist is unchanged.
No dependency is added.

## Exit Criteria

| Criterion | Evidence |
|---|---|
| Lock during every asynchronous state leaves the app locked with no late state publication | `VaultSessionTests`: lock during unlocking discards the completion; lock during an in-flight decrypt publishes nothing; a generation invalidated by lock stays invalid after re-unlock; lock clears published projections and cancels registered work |
| An unsupported capability cannot be invoked by menus, shortcuts, or deep links | `ProviderCapabilityTests`: every mutation is rejected from every entry point when its capability is absent, the provider records no mutation, and mutations require a gate-issued `CapabilityAuthorization` by construction |
| Identity collisions are impossible across providers, accounts, and spaces | `ProviderIdentityTests`: identical raw identifiers are distinct across providers, accounts, and shares, and survive a Codable round trip |
| Fidelity metadata and unknown-field pass-through | `ProviderCacheEnvelopeTests`: lossy labeling is explicit, payloads round-trip byte for byte including fields no VaultSquire version understands, and sync state stays opaque |

The merge condition in `DELIVERY.md` row 2 is the race/capability/identity
test set above, which runs in the hosted `macos-26` lane via `scripts/ci.sh`.

## Outstanding Workstream 1 Exit Evidence

Workstream 2 consumes no outstanding Workstream 1 evidence: it depends on no
hardware measurement, accessibility result, or sandbox outcome. Per
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
- Generated 16/32/64 px icon review (assets derived and recorded in
  `ICON_PROVENANCE.md` on 2026-08-09; the 1:1 review remains owed).

Presence in `main` is not evidence that a criterion passed; a row is marked
passed only when the evidence exists.
