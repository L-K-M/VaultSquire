# VaultSquire Comprehensive Product And Implementation Plan

- Status: proposed, no implementation started
- Last updated: 2026-07-31
- Product: clean-room native macOS client named VaultSquire
- Providers: self-hosted Vaultwarden and Proton Pass through the official CLI

## 1. Executive Recommendation

Proceed with a completely new, independently expressed native macOS application
written in Swift. Before implementation, satisfy the history-isolation gate in
[`KEYGUARD_FORK_ASSESSMENT.md`](KEYGUARD_FORK_ASSESSMENT.md); earlier planning
history is not an approved coding context. The first private preview should
prove Vaultwarden authentication, cryptographic interoperability, encrypted
local persistence, offline unlock, browsing, and search before it can modify a
vault. Add safe online writes only after cross-client and two-client conflict
tests pass.

The Keyguard fork path is permanently rejected because its license does not
grant the rights VaultSquire needs. Keyguard source is excluded from the design
and implementation process. Do not copy or adapt its code, architecture, tests,
strings, assets, or detailed behavior. Only vague product inspiration from
ordinary use is allowed. See
[`KEYGUARD_FORK_ASSESSMENT.md`](KEYGUARD_FORK_ASSESSMENT.md).

Support Proton Pass through the official user-installed CLI, not through a
private API reimplementation or copied Proton code. Reading is a required
provider capability. Writing is a product goal and is enabled operation by
operation only when the tested CLI version offers a machine-readable,
secret-safe path. A write that requires a password, TOTP seed, item content, or
other private value in process arguments, environment variables, logs, or any
plaintext file remains disabled. See
[`PROTON_PASS_RESEARCH.md`](PROTON_PASS_RESEARCH.md).

### Decision Summary

| Decision | Initial choice |
|---|---|
| Product codebase | New, history-isolated clean-room VaultSquire implementation |
| Platform | Native macOS 14 or later |
| Architectures | Apple Silicon `arm64`; Intel requires a later ADR and native Intel testing |
| Language | Swift 6 with strict concurrency |
| UI | SwiftUI shell with focused AppKit integration |
| Distribution | Developer ID signed, hardened, notarized direct download first |
| First provider milestone | Vaultwarden read-only preview |
| Second provider milestone | Proton Pass through user-installed official CLI |
| Initial server target | Vaultwarden 1.37.1, then an explicit tested support window |
| Preview capability | Read-only online and offline vault |
| First general-use capability | Online core item writes with conflict detection |
| Local data | Vaultwarden-native ciphertext and AEAD-wrapped lossy Proton snapshots in encrypted SQLite |
| Search | Local index over a deliberately limited decrypted projection |
| Telemetry | None by default; local allowlisted diagnostics only |
| Proton Pass | Selected CLI adapter; read required, secret-safe writes capability-gated |
| Keyguard fork | Permanently rejected; source excluded from implementation |
| Product identity | `VaultSquire`; canonical artwork at `media-sources/icon.png` |

## 2. Product Definition

VaultSquire is for a person who operates or is invited to a self-hosted
Vaultwarden instance and wants a focused macOS client that feels native, opens
quickly, and finds credentials immediately. It is not initially an enterprise
administration console, a server management tool, or a complete replacement
for every official Bitwarden client feature.

### Product Principles

- Optimize the launch, unlock, search, reveal, and copy loop first.
- Keep network, protocol, cryptography, persistence, and UI responsibilities
  visibly separate.
- Treat the configured server, every response, and every encrypted field as
  untrusted input.
- Fail closed on unknown cryptographic forms while preserving their ciphertext.
- Keep a last known-good encrypted snapshot through failed or cancelled syncs.
- Make lock and logout concrete security state transitions, not cosmetic views.
- Prefer an explicit unsupported state to lossy conversion or silent fallback.
- Implement one provider well before generalizing provider behavior.
- Keep provider-specific auth, crypto, sync cursors, and conflict rules inside
  the provider implementation.
- Keep Keyguard source and source-derived implementation detail outside all
  coding contexts; VaultSquire must remain independently expressed.
- Treat the Proton CLI as an external executable and protocol boundary, never as
  source to copy or a library to link.
- Measure launch and search performance on release builds and oldest hardware.
- Avoid features that increase the secret surface until their threat model and
  test oracle exist.

### Product Identity

- The product and application name is `VaultSquire`.
- The canonical source icon is `media-sources/icon.png`.
- Keep the source image unchanged; generate the required macOS AppIcon sizes and
  asset catalog during implementation.
- Validate source dimensions, color profile, transparency, small-size legibility,
  and ownership before the first signed build.
- Use original bundle identifiers, screenshots, copy, and visual design.
- Do not use Keyguard, Bitwarden, Vaultwarden, or Proton logos or imply
  affiliation.

### Meaning Of "Add Account"

The requested account-creation experience means adding an existing account to
VaultSquire, not registering a new user on the Vaultwarden server.

The first screen is one form with:

| Field | Behavior |
|---|---|
| Vaultwarden URL | Required full base URL, including port and path prefix |
| Email | Required; normalization occurs only according to protocol rules |
| Master password | Required; never trimmed, persisted, logged, or sent raw |
| Sign in | Validates URL and TLS before transmitting account-derived material |

If the server challenges for a second factor, the same flow advances to a
focused 2FA view that shows only methods advertised by the server. It returns
to the original form without clearing non-secret fields when the user goes
back. A remembered-device control appears only when the chosen provider and
server support it.

Actual server-side registration is deferred. Registration creates user keys,
an RSA identity, KDF settings, and recovery-critical wrapped material. A defect
can create an account no conforming client can recover. The route research is
retained in [`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md#registration)
for a later, separately reviewed feature.

## 3. Users And Core Journeys

### Add An Existing Vaultwarden Account

1. The user enters URL, email, and master password in one form.
2. VaultSquire parses the URL locally and rejects credentials in URLs, query
   strings, fragments, unsupported schemes, and ambiguous normalization.
3. VaultSquire establishes HTTPS with system trust before using the email or
   password. Private certificate authorities work after installation into the
   system trust store; there is no certificate bypass.
4. VaultSquire fetches only unauthenticated server configuration. No email or
   password-derived value has left the process at this point.
5. VaultSquire resolves the effective API and identity origins. If either
   differs from the entered origin, VaultSquire displays it and requires
   confirmation.
6. Only after origin approval, VaultSquire sends the normalized email to the
   approved prelogin endpoint and receives KDF parameters.
7. VaultSquire derives authentication material locally and submits the login.
8. If required, VaultSquire presents supported second-factor choices.
9. VaultSquire validates the returned key hierarchy before retaining account
   state, then downloads and atomically stores the first encrypted snapshot.
10. The vault opens only after the complete login and initial snapshot pass.

### Launch And Vaultwarden Unlock

1. The process displays a lightweight locked shell without opening the vault.
2. The user unlocks the Vaultwarden cache with the Vaultwarden master password.
3. Touch ID quick unlock may be enabled only after the device-bound Keychain
   retrieval design passes its Workstream 8 security spike.
4. The first visible vault rows are decrypted in bounded batches.
5. The search index builds incrementally without blocking the main actor.

### Proton Cached Unlock

1. VaultSquire never asks for the Proton account password or Pass extra
   password; the official CLI/browser owns Proton authentication.
2. The lossy Proton snapshot is encrypted under a random device-only cache key.
3. Releasing that cache key after app lock requires local authentication. Proton
   has no master password for VaultSquire to verify, so the Keychain record
   holding the cache key is the only available gate and it must be access
   controlled; an unauthenticated read would make Proton lock cosmetic while
   Vaultwarden lock stays cryptographic. The normative Keychain policy and its
   non-biometric fallback are in
   [`ARCHITECTURE.md`](ARCHITECTURE.md#keychain-and-biometrics).
4. If the cache key is unavailable, VaultSquire discards the unreadable snapshot
   and refetches through an authenticated CLI session; it does not ask for or
   derive a Proton password.
5. Proton unlock is therefore bound to a device-local factor rather than to a
   user secret. That is a weaker guarantee than Vaultwarden's master-password
   unlock, and the product states it plainly instead of implying the two
   providers lock alike.

### Quick Search And Copy

1. A configurable global shortcut presents a reusable native search panel.
2. Keyboard focus lands in search; results update locally as the user types.
3. Search covers title, username, host, folder, and collection; archived
   items are excluded from default results and appear only through the
   explicit Archived filter.
4. Passwords, TOTP seeds, card numbers, private keys, and hidden fields are not
   indexed by default.
5. Return opens the selected record; explicit shortcuts copy username or
   password when policy permits.
6. Secret clipboard values expire after a finite default interval and are
   cleared only if the pasteboard change count shows VaultSquire still owns
   the current value.

### Create And Archive An Entry

1. Create and archive are online-only actions gated by the provider capability
   set; they are absent from the read-only preview and from every offline
   session.
2. Creating an entry composes a new item from current explicit user input only,
   encrypts it under the provider's own rules, and never reuses a cached
   projection as write content.
3. Archiving hides an entry from default browsing and search without deleting
   it. It is a distinct state from trash: `archivedDate` and `deletedDate` are
   separate fields, and neither action is ever presented as the other.
4. On Vaultwarden, archive and unarchive are per-user state. Another member of
   the same organization does not observe the change, and no item content is
   rewritten.
5. Where a provider exposes no archive operation, the action is disabled with a
   precise explanation rather than mapped onto trash, deletion, or a favorite.
6. Every create, archive, and unarchive is followed by an authoritative read
   before the result is presented as final.

### Sync And Offline Use

- The last complete encrypted snapshot remains available offline unless
  VaultSquire has durably observed a key-hierarchy rotation. In that case the
  prior snapshot remains intact for transactional recovery but offline unlock is
  blocked until full online re-authentication validates and commits the
  replacement hierarchy and snapshot.
- Offline unlock displays snapshot age and a clear stale/offline indicator.
- The preview is offline read-only.
- Sync writes a candidate snapshot generation and publishes it only after complete
  parsing, key validation, and a successful database transaction.
- Notifications are hints; authoritative sync repairs gaps and reconnects.
- A sync failure never replaces a usable snapshot with an empty or partial one.

### Lock And Logout

- Lock cancels sensitive tasks, invalidates the session generation, closes the
  decrypted store, removes decrypted projections and search indexes, dismisses
  secret UI, invalidates local authentication contexts, and conditionally
  clears the app-owned clipboard value.
- Logout additionally removes refresh credentials, remembered 2FA material,
  quick-unlock records, encrypted account storage, and account preferences.
- The UI always distinguishes locked, offline, expired-session, and logged-out
  states.

## 4. Scope

### Vaultwarden Read-Only Preview

| Included | Deliberately excluded |
|---|---|
| One Vaultwarden account | Multiple active accounts |
| URL/email/password form and optional 2FA | Server-side account registration |
| PBKDF2 and Argon2id | SSO, passkey login, login with device |
| TOTP, email, and recovery code | YubiKey OTP, Duo, and WebAuthn until separately tested |
| Personal and organization item reads | Organization administration |
| Login, secure note, card, identity, and SSH key display | Sends and unknown item mutation |
| Folders, favorites, collections, and effective permissions | Collection administration |
| Archived-state reads: parse per-user `archivedDate`, keep archived items out of default browse/search, and offer an explicit Archived filter | Archive and unarchive writes |
| Encrypted offline snapshot and unlock | Offline writes |
| Browse, reveal, copy, and local search | Import, export, browser extension, passkeys |
| Manual, activation-triggered, and low-frequency periodic repair sync while the app runs | Always-on helper or background daemon |
| Lock, logout, clipboard expiry, inactivity lock | Automatic update framework before release hardening |

### First Vaultwarden General-Use Release

The first general-use release adds online create/update and a password generator
for core item types. It remains read-only while offline. It performs a
latest-record preflight, supplies the server revision verbatim, presents
conflicts the server detects, and never blindly retries an ambiguous write.
Vaultwarden can accept a stale delta just under two seconds because it truncates
to whole seconds and rejects only values greater than one. Delete, restore,
favorite/partial, folder, settings, and other unguarded mutations remain
deferred until each residual data-loss behavior is explicitly accepted.

Archive and unarchive are the one deliberate exception in that unguarded family,
because the product commits to archiving as a basic capability and the residual
risk is bounded. At the pinned target the archive routes carry no
`lastKnownRevisionDate` precondition, so they are last-write-wins, but the state
they write is a single per-user timestamp: it is stored per user rather than on
the shared cipher, it is fully reversible through unarchive, it rewrites no item
content, and a lost race can only leave an item archived or unarchived — never
damaged. Shipping archive therefore requires an endpoint-specific
last-write-wins ADR that records exactly that reasoning, plus:

- use only the dedicated archive/unarchive routes; never set `archivedDate`
  through a full-object cipher update, because that would put the entire
  encrypted object into a race whose blast radius is item content rather than
  one flag;
- treat the bulk archive/unarchive routes as a separate later decision, since a
  partially applied batch has no defined reconciliation;
- refresh the affected item authoritatively after success or ambiguity.

### Proton CLI Provider

Proton Pass support is a committed product direction after the Vaultwarden core
establishes the shared native shell, lock lifecycle, storage, and search.

Required read scope:

- discover or let the user select an official `pass-cli` executable;
- verify a tested CLI version and authenticated session;
- delegate Proton login, refresh, keys, and network traffic to the CLI;
- list vaults/shares and read supported item types through machine JSON output;
- immediately wrap decrypted CLI output in a VaultSquire AEAD cache envelope for
  persistence; never describe it as Proton-native ciphertext;
- build the search projection in memory and support fast cached launch/unlock;
- preserve the CLI snapshot as explicitly lossy and never use its item fields to
  reconstruct a write.

Target write scope:

- detect write capabilities per tested CLI version and operation;
- prefer documented JSON over stdin or another non-argv machine channel;
- enable create, update, trash, restore, delete, vault, and sharing operations
  only where the tested CLI actually exposes the operation and its complete
  private input has a reviewed secret-safe transport; an operation the CLI does
  not offer is absent, not approximated;
- refresh the authoritative CLI snapshot after every successful or ambiguous
  write;
- disable an operation with a precise explanation when the CLI requires secret
  values in argv, environment variables, logs, or any plaintext file;
- never claim offline Proton writes unless the CLI exposes a tested conflict and
  revision contract.

"If possible" means write support is capability-driven, not best-effort. Safety
requirements are not weakened to obtain nominal write parity.

Provider capability differences are exposed rather than hidden. At the researched
CLI revision Proton Pass has no archive command and its documented item deletion
is permanent, so VaultSquire's archive action is unavailable for Proton accounts
and its delete action must not borrow Vaultwarden's reversible-trash wording.
Feature parity across providers is never obtained by mapping one provider's
operation onto a different provider's nearest-looking operation.

### Later Releases

- Multi-account unified search.
- Attachment upload and authenticated download.
- Delete, restore, favorite/partial, folder, and settings mutations after an
  explicit last-write-wins decision for each endpoint.
- SignalR notifications with full-sync recovery.
- AuthenticationServices AutoFill Credential Provider.
- Safari Web Extension only for workflows the system provider cannot express.
- TOTP AutoFill, passkeys, Sends, import/export, and advanced organization use.
- Additional Proton CLI operations as its safe machine interface expands.

## 5. Native macOS Technical Direction

### Application Shape

Use a SwiftUI `App` with a small AppKit bridge for application lifecycle,
workspace events, a reusable Quick Search `NSPanel`, and behavior SwiftUI does
not express reliably. Keep the initial app a modular monolith. Do not create a
daemon, XPC service, browser extension, or helper merely to express layering.

Use these isolation boundaries:

| Boundary | Ownership |
|---|---|
| `@MainActor AppModel` | Window, selection, navigation, and display state |
| `VaultSession` actor | Session generation, opaque provider unlock context, projections |
| Provider session actor | Authentication, provider key lifetime, token replacement, request sequencing |
| Provider sync actor | Sync coalescing, cursor/revision state, candidate publication |
| Database queue/pool | Transaction ordering and migration serialization |

Every unlock receives a new session generation. Results from KDF, network,
database, decrypt, and search work must be discarded when their generation no
longer matches. This prevents a late task from repopulating state after lock.

### Preferred Platform Stack

| Need | Preferred direction | Required proof gate |
|---|---|---|
| UI | SwiftUI plus focused AppKit | Search panel focus, Spaces, VoiceOver |
| Concurrency | Swift 6 strict concurrency | No unchecked secret-bearing wrappers |
| Network | Ephemeral `URLSession` plus isolated `Process` bridge | Vaultwarden transport and Proton CLI process tests |
| Database | GRDB over SQLCipher | Apple Silicon packaging, cache-envelope, crash/WAL tests |
| Key storage | Data Protection Keychain | Device-only ACL and Touch ID invalidation |
| Search | In-memory normalized projection | Leakage and 100,000-item benchmarks |
| Shortcut | Native registered shortcut library | Conflict and accessibility behavior |
| Updates | Manual signed beta, then Sparkle for direct distribution | Signing and sandbox installer design |

The database choice remains provisional until a release-mode spike proves
licensing, Apple Silicon packaging, migrations, WAL behavior, backup,
and crash recovery. No local database library is a substitute for preserving
Vaultwarden-native ciphertext, immediately wrapping lossy Proton CLI output, and
enforcing Vaultwarden cryptography plus the external CLI command boundary
correctly.

App Sandbox is preferred but not allowed to make the selected Proton CLI provider
impossible. Phase 0 must test user-selected executable access, child-process
sandbox inheritance, CLI session/keyring access, and security-scoped bookmarks.
If the official CLI cannot function safely inside App Sandbox, ship the direct
Developer ID build with Hardened Runtime, no App Store distribution, and the
smallest reviewed non-sandboxed process/file access needed for the CLI. Do not
add a privileged helper.

### Performance Budgets

These are release gates to calibrate in the workstream that first implements
each scenario, not marketing promises. KDF duration is reported separately
because server-selected work is a security control. This table is the
controlling copy; the table in
[`ARCHITECTURE.md`](ARCHITECTURE.md#10-performance-and-quality-gates) mirrors it.

| Scenario | Corpus | Provisional p95 gate |
|---|---|---:|
| Cold process launch to locked shell | Empty account store | 750 ms |
| Warm shortcut to visible search panel | Unlocked 10,000-item snapshot | 100 ms |
| Successful quick auth to database ready | Encrypted 10,000-item snapshot | 200 ms |
| First 100 list rows after key availability | 10,000 items | 500 ms |
| In-memory search query | 10,000 items | 50 ms |
| In-memory search query | 100,000 items | 250 ms |
| Keystroke to rendered search results | 10,000 items | 75 ms |
| Open an already indexed item | 10,000 items | 100 ms |
| Incremental sync with no revision change | Encrypted 10,000-item snapshot | No cipher decryption or list rebuild |
| Main-thread stall in a core flow | Unlocked 10,000-item snapshot | No unexplained interval over 50 ms |

Every gate binds at the corpus named in its row. Runs at the other generated
corpus sizes are recorded as trend data and do not block a release on their own.
Search computation completes off the main actor; the separate
keystroke-to-render gate includes result publication and rendering.

Measure on a representative Apple Silicon Mac with generated vaults of 1,000,
10,000, and 100,000 items. Record build mode, cache state, database state, KDF
settings, and hardware with every result. Any later Intel-support ADR must add
equivalent native Intel release measurements before changing the manifest.

## 6. Vaultwarden And Proton Provider Boundary

Provider support is an application boundary, not a claim that both password
managers have the same model. Implement one small compiled provider facade with
a `VaultwardenProvider` and a `ProtonCLIProvider`, not six protocols or a runtime
plug-in framework. Build Vaultwarden first, then add the CLI provider without
changing shared identity, lock, search, or capability semantics.

| Seam | Generic responsibility | Provider-owned detail |
|---|---|---|
| Session | Login state, challenge presentation, lock, logout | Vaultwarden grant flow or CLI session/login process |
| Catalog | Accounts and user-visible spaces | Organization, collection, share, vault, role semantics |
| Records | List, fetch, and capability-gated mutations | Vaultwarden DTOs or documented CLI commands/JSON |
| Sync | Publish validated changes or snapshots | Revision date versus full CLI refresh and command reconciliation |
| Capabilities | Enable exact UI actions | Folder, trash, alias, sharing, passkey, attachment behavior |
| Cache envelope | Protect provider state at rest | Lossless Vaultwarden ciphertext or lossy app-encrypted CLI snapshot |

Use opaque compound identities. A local item key includes provider, account,
provider space/share identity, and item identity. Do not assume an item ID is
globally unique, a share is a vault, a cursor is a timestamp, trash equals
deletion, folders exist, or every provider can incrementally sync.

Use a small canonical projection only for shared UI and search:

- display title and subtitle;
- canonical item category where a lossless mapping exists;
- usernames, websites, and non-secret folder/collection labels;
- action capabilities;
- a stable local reference back to the provider cache envelope.

Do not make one universal crypto interface. `VaultwardenProvider` owns its
protocol cryptography, authentication, key rotation, conflicts, and sync state.
`ProtonCLIProvider` delegates those responsibilities to the official CLI and
owns only process execution, JSON mapping, app cache encryption, refresh, and
capability calculation. Do not flatten Vaultwarden native fields for writes. Do
not use cached or freshly fetched lossy Proton item fields to synthesize writes;
submit user-provided content plus only reviewed opaque identifiers/concurrency
tokens through a documented CLI write command and refresh afterward.

No Proton source code, private API model, or linked Proton library belongs in
VaultSquire. The integration executes the official user-installed CLI as a
separate process. One fake provider facade proves state and capabilities before
the two production providers are added in sequence.

## 7. Detailed Work Breakdown

Workstreams are this document's controlling sequence. The phase names used by
[`ARCHITECTURE.md`](ARCHITECTURE.md#9-delivery-plan) and the stage names used by
[`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md#vaultwarden-evidence-delivery-sequence)
are restatements of the same work for their own subject matter, not a second
schedule. Phase 0 is a proof gate, not an alias for completing Workstreams 0-5:

| Phase name used elsewhere | Controlling workstreams |
|---|---|
| Phase 0 protocol/crypto proof and early feasibility spikes | Workstreams 0-3, followed by the headless discovery/authentication contract slice at the start of Workstream 4 |
| Phase 1 read-first preview | Remainder of Workstream 4, then Workstreams 5-8 |
| Phase 2 safe mutation | Workstream 9 |
| Phases 3-4 Proton CLI read and safe writes | Workstream 10 |
| Phases 5-6 compatibility depth and extensions | Workstream 11 |

The Workstream 4 headless slice begins only after Workstreams 0-3 and does not
pull its account UI or later storage work into Phase 0. Individual spikes named
in sections 5 and 13 resolve inside a specific workstream: the sandbox and
process spike in Workstream 1 during Phase 0, the storage and
database-encryption spike in Workstream 5 during Phase 1, and the Touch ID
quick-unlock spike in Workstream 8 during Phase 1. A phase gate is met only when
the mapped work and its exit criteria pass; declaring a phase complete does not
reorder a workstream.

### Workstream 0: Governance And Evidence

Deliverables:

- Record architecture decisions for macOS target, distribution channel,
  database stack, crypto dependencies, provider boundary, and support policy.
- Pin source revisions and container digests used as compatibility evidence.
- Establish a dependency/license inventory and source hygiene rules.
- Define synthetic fixture generation and prohibit production vault fixtures.
- Record Apache License 2.0 as the selected source license before adding code.
- Record `media-sources/icon.png` as the canonical product artwork.

Exit criteria:

- Every dependency candidate has a source, version, license, checksum strategy,
  update owner, and reason for inclusion.
- Keyguard source and source-derived implementation details are absent from the
  coding environment and prompts.
- A reviewed history-isolated implementation context exists; application code is
  blocked until this provenance gate passes.
- No design assumes permission to copy Bitwarden, Vaultwarden, or Proton
  implementation code.

### Workstream 1: Native Shell And Performance Harness

Deliverables:

- Swift 6 project with strict concurrency, Hardened Runtime, and an App Sandbox
  feasibility configuration.
- Locked shell, settings, one-window lifecycle, and Quick Search panel spike.
- Structured logging wrapper with an allowlist rather than best-effort redaction.
- Signposts and XCTest performance fixtures for launch and search panel display.
- Apple Silicon release build and minimal signed local artifact.

Exit criteria:

- The empty locked shell meets the launch budget on named baseline hardware.
- VoiceOver, keyboard focus, Full Keyboard Access, multiple Spaces, and Escape
  dismissal work for the panel.
- Release entitlements contain no unexplained capability.
- A standalone process spike records whether the official Proton CLI can access
  its selected executable, session directory, and keyring under App Sandbox.

### Workstream 2: Domain, Session, And Provider Contracts

Deliverables:

- Explicit logged-out, authenticating, challenged, locked, unlocking, unlocked,
  syncing, and logging-out states.
- Account and item identities namespaced by provider and account.
- Provider capability values consumed by every UI action.
- Provider cache envelope and a narrow decrypted display projection. Vaultwarden
  retains native ciphertext; Proton CLI snapshots use a VaultSquire AEAD wrapper.
- One fake provider facade for state, cancellation, capability, and
  unknown-field tests; do not create a protocol per conceptual seam.

Exit criteria:

- Lock during every asynchronous state leaves the app locked with no late state
  publication.
- An unsupported capability cannot be invoked by menus, shortcuts, or deep links.

### Workstream 3: Vaultwarden Crypto Harness

Deliverables:

- PBKDF2 and Argon2id derivation with defensive bounds.
- Master authentication hash, HKDF stretching, user key unwrap, RSA organization
  key unwrap, and authenticated `EncString` support.
- Constant-time tag validation and generic decryption failures.
- Generated known-answer, malformed-input, and official-client differential
  fixtures for all supported forms.
- Fuzz targets for encrypted strings, base64, key material, and KDF values.

Exit criteria:

- Byte-for-byte fixture compatibility at the pinned source revision.
- No plaintext is returned before authentication succeeds.
- Unknown or unsupported cryptographic types are retained and rejected without
  algorithm substitution.

### Workstream 4: Environment, Transport, And Authentication

Deliverables:

- URL parser that preserves path prefixes and ports.
- Ephemeral `URLSession`, bounded responses, strict redirects, system trust,
  proxy support, cancellation, and safe retry classification.
- Configuration discovery, prelogin, password login, 2FA continuation, refresh
  replacement, and typed error mapping.
- One-form add-account UI followed by an optional challenge screen.
- Keychain storage with atomic refresh-token replacement and remembered 2FA
  material.

Exit criteria:

- Contract tests pass for path prefixes, private CAs, redirects, PBKDF2,
  Argon2id, every claimed 2FA provider, token expiry, and rate limiting.
- Passwords, OTPs, tokens, complete URLs, and account identifiers do not appear
  in logs, errors, crash metadata, URL cache, cookies, or temporary files.

### Workstream 5: Encrypted Persistence And Offline Unlock

Deliverables:

- Versioned encrypted database, migrations, integrity diagnostics, and atomic
  last-known-good snapshot publication.
- A device-only Keychain key for database encryption and a versioned generic
  cache-envelope AEAD exercised with a test-only in-memory key and synthetic
  fake-provider data in this workstream. No Proton cache key or CLI snapshot is
  created yet.
- Vaultwarden-native ciphertext tables, opaque provider sync state, and a blob
  boundary that proves future lossy snapshots can be stored without flattening
  them into Vaultwarden records.
- Vaultwarden offline master-password unlock and stale-snapshot presentation.
- Crash, cancellation, corruption, truncation, rollback, migration, and logout
  cleanup tests.

Exit criteria:

- Filesystem inspection finds no fixture plaintext in the database, WAL,
  journals, temporary files, preferences, or state restoration.
- Process death at every commit stage yields either the prior or complete new
  generation, never a mixed generation.
- Logout post-condition tests find no account credential or cache key.

### Workstream 6: Sync, Decryption, And Read Models

Deliverables:

- Server-revision-gated aggregate sync with request coalescing, matching
  before/after account-revision checks, explicit eventual-consistency limits,
  and low-frequency periodic repair sync while the app is running.
- Tolerant DTO decoding and lossless raw response retention.
- User, organization, collection, folder, and core item decryption.
- Bounded incremental list projection and per-item detail decryption.
- Permission-aware action capabilities and unsupported-item placeholders.

Exit criteria:

- Personal and organization fixtures created by a tested official client render
  correctly.
- A malformed record cannot discard valid records or replace the prior snapshot.
- Collection restrictions prevent reveal and copy through every action path.

### Workstream 7: Vault UI And Search

Deliverables:

- Native sidebar/list/detail layout, trash/archived/favorites/folder/collection
  filters, and keyboard commands. Archived and trashed items are separate
  filters and are both excluded from the default vault list and from search
  results unless their filter is active.
- Incremental search over approved fields with accent/case normalization,
  prefix matching, quoted terms, and deterministic ranking.
- Quick Search, explicit reveal/copy, clipboard expiry, and URI confirmation.
- Accessibility labels that do not announce concealed secrets unexpectedly.
- 1,000, 10,000, and 100,000-item generated performance corpora.

Exit criteria:

- Launch, first-list, search, and item-open budgets pass in release builds.
- Search terms and secret values are absent from persistent storage and logs.
- Keyboard-only and VoiceOver test passes cover every core flow.

### Workstream 8: Security Hardening And Private Preview

Deliverables:

- Automatic lock on configured inactivity, screen lock, sleep, and session
  resignation.
- Optional Keychain-bound Touch ID quick unlock if its spike passes.
- Sanitized local support bundle with user preview.
- Hardened Runtime, signing, notarization, SBOM, provenance, and release runbook.
- External review scope and coordinated vulnerability disclosure process.

Exit criteria:

- All stop-ship gates in
  [`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md) that apply to the declared
  read-only preview manifest pass.
- Private preview users cannot encounter a known silent-data-loss path because
  the preview remains read-only.

### Workstream 9: Safe Online Mutations

Deliverables:

- Core item create and update with complete unknown-field preservation.
- Archive and unarchive through the dedicated per-user routes, with the
  endpoint-specific last-write-wins ADR recorded before the action ships.
- Per-object serialization, stale revision detection, ambiguous-write
  reconciliation, and explicit conflict UI.
- Cross-client reads and two-client races for every mutation.

Exit criteria:

- Ambiguous network outcomes reconcile before retry; deterministic stale writes
  outside the server tolerance are detected, and the nearly two-second residual
  window is characterized and documented.
- Every object type in the release manifest round-trips between VaultSquire and
  the tested official client without loss. Objects outside the manifest,
  including item and cryptographic forms VaultSquire does not render, are
  byte-preserved, shown as explicitly unsupported, and never mutated.
- Archive and unarchive converge to the same per-user state in the official
  client, and a lost race leaves the item's content untouched.
- Unsupported item and cryptographic forms remain byte-preserved and unwritten.

### Workstream 10: Proton CLI Provider

Deliverables:

- User-selected or discovered official CLI path with tested-version policy.
- No-shell process runner with bounded I/O, cancellation, timeout, and sanitized
  failures.
- CLI authentication/status flow that never captures the Proton password in
  VaultSquire.
- Vault/share and item read mapping with compound provider identifiers.
- Immediate AEAD wrapping of CLI JSON under a device-only Keychain cache key.
- User-presence-bound local release of that separate Proton cache key for cached
  unlock, with key-loss discard/refetch behavior.
- Full-refresh publication, in-memory search projection, and stale-state UI.
- Per-version read/write capability manifest and disabled-action explanations.
- Secret-safe write adapter for every CLI operation whose complete private input
  uses stdin or another approved non-argv channel.
- Post-write full refresh and ambiguous-result reconciliation.
- Provider selection under the existing one-configured-account limit;
  concurrent Vaultwarden and Proton accounts remain disabled until Workstream 11.

Exit criteria:

- Read, launch, lock, search, and refresh budgets pass with generated Proton
  accounts at realistic sizes.
- Process argv, environment, logs, stderr persistence, temporary files, and crash
  reports contain no fixture secrets or item content.
- Every enabled write round-trips through an official Proton client and has
  interruption, cancellation, unsupported-version, and malformed-output tests.
- Unsafe write commands remain unavailable rather than using argv, environment
  variables, or plaintext files.
- Distribution and sandbox behavior are fixed in an ADR and tested on a clean Mac.

### Workstream 11: Extensions And Advanced Features

Each feature receives a separate threat model and phase gate:

- authenticated attachment transfer;
- notification transport and catch-up;
- multiple accounts;
- AuthenticationServices AutoFill extension;
- one-time-code AutoFill;
- Safari Web Extension;
- passkeys, Sends, import/export, and organization administration.

The main app remains the sole database writer. Any app extension opens a shared
store read-only, performs no migration or network sync, and fails closed when
its schema is incompatible.

## 8. Quality And Release Strategy

### Test Layers

| Layer | Primary purpose |
|---|---|
| Unit | Parsing, state transitions, capabilities, ranking, redaction, migrations |
| Known-answer | KDF, key hierarchy, encrypted strings, attachments, OTP |
| Differential | Byte-level interoperability with pinned reference output |
| Contract | Pinned Vaultwarden containers and fake/real Proton CLI command contracts |
| Integration | Keychain, encrypted database, crash recovery, proxy/TLS, extensions |
| UI/accessibility | Login, challenge, unlock, search, copy, lock, keyboard, VoiceOver |
| Performance | Launch, unlock, projection, search, sync processing, memory, energy |
| Fuzz/adversarial | Wire parsers, crypto framing, URLs, cache envelopes, large inputs |
| Release | Entitlements, signatures, notarization, SBOM, provenance, clean install |

Only scenarios applicable to a release's declared feature manifest block that
release. Test priority is not delivery phase. The exact matrix and blockers are
normative in
[`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md).

### Server Support Policy

Start with one current Vaultwarden release and its immutable container digest.
Add the prior release as a sentinel only after the current target passes. Run a
nonblocking scheduled lane against Vaultwarden `main/testing` as an early drift
signal. Record both the Vaultwarden package version and the Bitwarden
compatibility version returned by configuration; they are not interchangeable.

Support is declared only for tested combinations of:

- Vaultwarden version and image digest;
- database migration state;
- direct and path-prefixed reverse proxy topology;
- PBKDF2 and Argon2id;
- claimed 2FA providers;
- personal and organization records;
- macOS version and processor architecture.

### Release Sequence

| Milestone | Audience | Mutation policy | Promotion gate |
|---|---|---|---|
| Feasibility harness | Developers | None | Crypto and auth interoperability |
| Read-only alpha | Developers | None | Encrypted cache and local search |
| Hardened private beta | Invited users | None | Security, release, accessibility gates |
| Core-write beta | Invited users | Online only | Race and interruption tests |
| 1.0 | General users | Online core writes | External review and all stop-ship gates |
| Proton CLI read alpha | Developers | Read only | Process, mapping, cache, and search gates |
| Proton CLI beta | Invited users | Capability-gated safe writes | CLI-version and leakage gates |
| Proton CLI general availability | General users | Only manifest-approved writes | Cross-client and distribution review |

## 9. Risks And Responses

| Risk | Impact | Planned response |
|---|---|---|
| Private Bitwarden client API drift | Login, sync, or writes break | Pin support, probe capabilities, preserve unknown data, contract test |
| Crypto integration defect | Disclosure or irreversible data loss | Small boundary, known-answer/differential/fuzz tests, external review |
| Malicious KDF values | CPU or memory denial of service | Enforce reviewed lower and upper resource bounds before allocation |
| Unexpected KDF change by a hostile server | Cheap offline attack on the master password | Persist the last accepted KDF settings per account, require explicit confirmation for every later algorithm or parameter change rather than trying to rank mixed changes, and never derive below the reviewed floor |
| Concurrent or ambiguous write | Duplicate or lost data | Latest-record preflight, server revision, no blind retry, explicit residual tolerance |
| Unknown model round trip | Future fields lost | Preserve lossless Vaultwarden native data; never round-trip lossy Proton projections |
| Local plaintext leakage | Vault compromise | Encrypted store, memory-only projections, log allowlist, leakage tests |
| Clipboard or screen observer | Secret disclosure | Explicit copy, finite clear, concealed UI, honest residual-risk text |
| Dependency compromise | Build or update compromise | Minimal pinned dependencies, SBOM, provenance, isolated release build |
| Proton CLI drift | Read/write capability breaks | Pin tested versions, manifest capabilities, fail closed, refresh fixtures |
| Unsafe CLI write interface | Secrets leak through argv or files | Keep operation disabled until stdin/protected machine channel exists |
| CLI/App Sandbox incompatibility | Selected provider cannot run | Direct Developer ID fallback with Hardened Runtime and reviewed access |
| Keyguard contamination | License/provenance failure | Permanent source exclusion, provenance review, remove affected work |
| Provider abstraction overreach | Complex core that fits neither provider | Generalize identities/capabilities only; keep crypto and sync native |
| Performance regressions | Product misses central value | Budgets in CI, generated large vaults, oldest-hardware release profiling |

## 10. Proton CLI Implementation Gates

The provider route is selected. These gates determine which capabilities ship,
not whether VaultSquire tries a private Proton API instead.

### Read Gate

1. Use an official user-installed CLI selected or discovered with user
   confirmation. Do not bundle, link, or copy Proton code.
2. Allowlist exact tested CLI versions/build identities and command schemas;
   every unlisted patch release fails closed.
3. Execute by absolute path without a shell.
4. Prove authentication status, vault/share listing, item listing/view, error
   classification, cancellation, timeout, and session expiry.
5. Keep complete stdout in bounded memory, decode it, immediately encrypt any
   persisted snapshot with a VaultSquire cache key, and clear transient buffers.
6. Store compound account/share/item identifiers and mark the snapshot as lossy.
7. Prove App Sandbox operation or adopt the reviewed direct-distribution fallback.
8. Pass the same lock, logout, leakage, accessibility, and performance gates as
   Vaultwarden.

### Write Gate

For each CLI command independently:

1. Document the exact tested command and CLI version.
2. Require complete private input through stdin or another reviewed protected
   machine channel.
3. Put no password, TOTP seed, note, title, username, URL, item content, token,
   or other private value in argv or environment variables.
4. Materialize no private CLI request or response in any plaintext file,
   regardless of lifetime or location.
5. Treat stdout and stderr as secret-bearing and never persist either raw.
6. Define timeout, cancellation, ambiguous completion, and retry behavior.
7. Refresh from the CLI after success or ambiguity; never mutate the lossy cache
   as if it were authoritative.
8. Cross-read the result with an official Proton client.
9. Disable the capability automatically when the detected CLI version or command
   contract does not meet every requirement.

Current research indicates that some create operations may support JSON/stdin,
while current update commands expose secret field values through argv. Therefore
read support is committed, safe create may arrive before update, and unsafe
update remains disabled until the CLI contract improves.

## 11. Keyguard Rejection And Source Isolation

- The Keyguard fork path is closed because of license constraints.
- Keyguard source must not be used by implementation agents or contributors.
- No Keyguard code, translation, architecture, schema, tests, strings, assets,
  or detailed source-derived design may enter VaultSquire.
- Only vague, product-level inspiration from normal application use is allowed.
- Suspected contamination is removed and independently reimplemented; it is not
  cosmetically rewritten.
- [`KEYGUARD_FORK_ASSESSMENT.md`](KEYGUARD_FORK_ASSESSMENT.md) is the controlling
  source-isolation decision.

## 12. Implementation Rules For Future LLM Work

- Work in the numbered workstream order unless an ADR explicitly changes it.
- Do not begin application code until the Keyguard history-isolation gate passes.
- Before each feature, read the controlling plan, architecture, security, and
  pinned protocol sections.
- Never infer a stable API from one successful request.
- Never consult or use Keyguard source for implementation; this prohibition is
  absolute under the accepted source-isolation decision.
- Never paste or mechanically translate implementation code from Bitwarden,
  Vaultwarden, or Proton into this repository. Imported general-purpose
  dependencies require an explicit decision, compatible license, provenance,
  and review.
- Integrate Proton only by executing the user-installed official CLI; do not
  bundle, vendor, link, or copy it.
- Keep every protocol fixture synthetic and disposable.
- Add failure, cancellation, lock, and leakage tests with each happy path.
- Do not log raw requests or responses from a password manager protocol.
- Preserve unknown Vaultwarden-native data before adding its write support;
  never use cached or freshly fetched lossy Proton item fields to synthesize a
  write.
- Do not weaken TLS, KDF, Keychain, process isolation, or cryptographic checks to
  make a fixture pass.
- Do not start the next milestone until the current exit criteria are measured.
- Record source revisions and observed behavior whenever compatibility changes.
- Treat documentation changes as part of the implementation, not post-release
  cleanup.

## 13. Open Product Decisions

These are genuinely unresolved and may be decided either way:

| Decision | Recommended default | Deadline |
|---|---|---|
| SQLCipher packaging | Supported XCFramework or reproducible pinned community build | Workstream 5 storage spike |
| Default inactivity lock interval | Five minutes | UX prototype |
| Clipboard expiry presentation | Countdown affordance and the shortest offered preference value | UX prototype |
| Auto-update | Manual beta first, Sparkle only after updater threat review | Before 1.0 |
| Search notes | Exclude initially; test value versus sensitive token expansion | After read-only alpha |
| Old Vaultwarden support | Current release first, previous release as sentinel | After alpha |
| Proton CLI version list | The exact tested version strings, once each has passed | Workstream 10 spike |
| Archive last-write-wins ADR | Accept the bounded per-user residual; record it before the action ships | Core-write beta |

The following are already decided by a controlling document and are listed only
so they are not relitigated as if they were open. Changing one requires updating
its controlling document first:

| Settled policy | Controlling text |
|---|---|
| Independent VaultSquire source uses Apache License 2.0 | `LICENSE` and Workstream 0 |
| Initial releases support Apple Silicon `arm64` only | ADR 0001; Intel requires a later ADR and native test capability |
| Clipboard default expiry of 30 seconds, shorter-only preference | `SECURITY_AND_TESTING.md` clipboard invariants |
| Lock on inactivity, sleep, screen lock, and session resignation | `SECURITY_AND_TESTING.md` memory and lifecycle invariants |
| Touch ID quick unlock only with a Keychain ACL bound to retrieval | `SECURITY_AND_TESTING.md` Keychain invariants and `ARCHITECTURE.md` |
| Proton CLI allowlist fails closed on untested versions | Section 10 read gate and `SECURITY_AND_TESTING.md` |
| Proton writes enabled per operation after its protected-input contract passes | Section 10 write gate |
| App Sandbox only if CLI session/keyring access works; otherwise reviewed direct build | Section 5 and `ARCHITECTURE.md` distribution section |
| App Store is not a target while external CLI execution is required | Section 5 and `ARCHITECTURE.md` distribution section |

## 14. Source And Decision Hierarchy

Project-document precedence is:

1. `PLAN.md` controls product scope, sequence, and milestone manifests.
2. `SECURITY_AND_TESTING.md` controls security invariants and release gates.
3. `ARCHITECTURE.md` controls component, state, data, and provider boundaries.
4. `IMPLEMENTATION_REPORT.md` records pinned protocol evidence and proposed
   algorithms; it cannot weaken the first three documents.
5. The Keyguard file is a binding rejection/source-isolation decision; the
   Proton report describes the selected CLI integration and its limits.

If the first three documents conflict, implementation is blocked until all are
updated to one decision. Do not pick a convenient interpretation. A stricter
safety requirement can stop a feature even when the plan otherwise includes it.

Upstream source proves only what a pinned revision did. It does not create a
public protocol promise. Use evidence in this order:

1. Published user, security, and developer documentation.
2. Pinned Vaultwarden server source for the supported target.
3. Pinned official client behavior and generated black-box fixtures.
4. Pinned internal SDK source only as research evidence, subject to license.
5. Permissibly researched third-party behavior, excluding Keyguard source.
6. Inference, always labeled and covered by a test or an open decision.

This ordering governs how protocol facts enter the research documents. It is not
a licence for implementation work to read upstream source directly. Once a fact
is recorded here or in
[`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md), implementation consumes
the recorded fact and independently generated fixtures, matching the clean-room
input list in
[`KEYGUARD_FORK_ASSESSMENT.md`](KEYGUARD_FORK_ASSESSMENT.md#5-clean-room-vaultsquire-policy).
Reopening tier 2 through 4 during implementation, which is sometimes necessary to
resolve a protocol question a report left ambiguous, is a research task: record
the new fact in the report, keep the reading read-only, and copy or translate no
expression. Keyguard source remains excluded at every tier without exception.

The detailed source baseline and protocol evidence are in
[`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md). The security and release
requirements are in [`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md).
