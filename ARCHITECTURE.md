# VaultSquire Architecture

Status: Proposed
Last updated: 2026-07-31
Target: A fast, clean-room native macOS client for Vaultwarden and Proton Pass
through the official Proton CLI

## 1. Purpose

VaultSquire is a completely new, independently implemented native macOS password
manager client. It interoperates with Vaultwarden through the Bitwarden Client
API and with Proton Pass by executing the official user-installed CLI. The first
release is a
read-first desktop client: sign in through one URL/email/password form, complete
2FA when challenged, sync an encrypted vault, unlock locally, browse and search
items, copy credentials, and lock safely.

This document records two different kinds of information:

- **Observed baseline** describes behavior found in pinned upstream sources.
- **VaultSquire decision** defines the architecture to implement here.

The allowed upstream repositories are protocol research inputs, not source
dependencies. No Bitwarden, Vaultwarden, or Proton implementation code is to be
copied into this project. Keyguard source is excluded entirely from
implementation research and coding contexts under
[`KEYGUARD_FORK_ASSESSMENT.md`](KEYGUARD_FORK_ASSESSMENT.md).

Detailed endpoint, wire-format, and cryptographic evidence is cataloged in
[`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md). This document is
normative for component and data boundaries. [`PLAN.md`](PLAN.md) controls
product scope and sequence. [`SECURITY_AND_TESTING.md`](SECURITY_AND_TESTING.md)
controls security invariants and release gates. The report supplies pinned
evidence and does not override those decisions.

### Goals

- Native macOS startup, navigation, accessibility, and system integration.
- Correct Vaultwarden authentication, KDF, encryption, and sync behavior.
- Proton read support and capability-gated secret-safe writes through the
  external official CLI.
- No intentional persistence of decrypted vault data.
- A small auditable security boundary around keys and decrypted values.
- Forward-compatible protocol decoding and explicit capability handling.
- Provider-scoped identities and cache envelopes that do not bake Bitwarden wire
  models or Proton CLI JSON into shared UI or search code.
- Original VaultSquire identity using `media-sources/icon.png` as the canonical
  source artwork.
- Measurable performance rather than inferred performance claims.

### Initial non-goals

- Full feature parity with official clients.
- Bitwarden-hosted service support as a release requirement.
- Offline mutation and conflict resolution.
- Organization administration, SSO, Send, SSH agent, or emergency access.
- Browser autofill, passkeys, or a Safari extension.
- Import and export.
- Direct Proton private API, copied/linked Proton code, or offline Proton writes.

## 2. Evidence Base

Research was performed on 2026-07-31 against immutable revisions:

| Project | Revision | Relevance |
| --- | --- | --- |
| Bitwarden clients | [`cfc7e4d3376127713dafa7a5924a17f4d101a05f`](https://github.com/bitwarden/clients/tree/cfc7e4d3376127713dafa7a5924a17f4d101a05f) | Desktop behavior and protocol usage |
| Vaultwarden | [`2629bcbe1380c894e3a7f52cafcac3988edb8fbb`](https://github.com/dani-garcia/vaultwarden/tree/2629bcbe1380c894e3a7f52cafcac3988edb8fbb) | Target server implementation |
| Bitwarden internal SDK | [`4bf6b5b58f4a099e2a39ff230d5804396560aff8`](https://github.com/bitwarden/sdk-internal/tree/4bf6b5b58f4a099e2a39ff230d5804396560aff8) | Stability and licensing constraints |
| Bitwarden server policy | [`85890318551ee8a2036bfbfb3c1135b98f1a4dce`](https://github.com/bitwarden/server/tree/85890318551ee8a2036bfbfb3c1135b98f1a4dce) | Trademark constraints |
| Proton Pass CLI | [`554fa9217c9451c3accaa52ad39d9141a9089911`](https://github.com/protonpass/pass-cli/tree/554fa9217c9451c3accaa52ad39d9141a9089911) | Source evidence for external command-contract tests; not itself a compatibility contract |

The latest Vaultwarden release observed during research was
[`1.37.1`](https://github.com/dani-garcia/vaultwarden/releases/tag/1.37.1),
published 2026-07-29.

Proton CLI `2.2.4` was published on 2026-07-31 after the pinned source-evidence
baseline above. It is untested and unsupported until its exact executable and
command schemas pass the capability gates.

### Observed baseline

- Vaultwarden describes itself as an alternative implementation of the
  Bitwarden Client API and lists broad, but not complete, compatibility
  [VW-README].
- The official desktop client is an Electron main/preload/Angular renderer
  application with shared TypeScript libraries and native Rust services
  [BW-MAIN] [BW-PRELOAD] [BW-WINDOW] [BW-RUST].
- Its desktop persistence backend assigns an entire `electron-store` object
  synchronously. A cache wrapper can debounce writes by 200 ms with a 5 second
  maximum wait [BW-STORE] [BW-CACHE].
- Encrypted ciphers are disk state. Decrypted cipher views and failed
  decryptions are memory state cleared on lock and logout [BW-CIPHER-STATE].
- Password login obtains KDF configuration before deriving authentication
  material, handles token and two-factor responses, installs account state,
  unlocks, then runs a full sync and migrations [BW-PASSWORD-LOGIN]
  [BW-LOGIN] [BW-LOGIN-SUCCESS].
- The desktop main process asks the renderer to check sync every five minutes,
  while the renderer normally performs a full sync only when the previous sync
  is at least six hours old [BW-SYNC-TIMER] [BW-APP] [BW-APP-SYNC]. Full sync
  first checks the account revision and coalesces duplicate network calls
  [BW-FULL-SYNC].
- Targeted notification handlers fetch or delete affected objects and can fall
  back to broader sync behavior [BW-CORE-SYNC].
- Basic search repeatedly normalizes item fields, while advanced search builds
  an in-memory Lunr index [BW-SEARCH] [BW-LUNR].
- On macOS, Touch ID is prompted before a separate generic Keychain lookup.
  The underlying native service uses generic password operations without
  access-control flags [BW-BIOMETRIC] [BW-KEYCHAIN].

These observations explain compatibility requirements. They do not require
VaultSquire to reproduce upstream implementation choices.

## 3. Architecture Decisions

| ID | VaultSquire decision | Reason |
| --- | --- | --- |
| D1 | Use SwiftUI with targeted AppKit integration. | Native lifecycle, accessibility, menus, Keychain, and low runtime overhead. |
| D2 | Build an independent protocol and crypto implementation. | The internal SDK is unstable and its restrictive license path is unsuitable for a generally distributed Vaultwarden client [BW-SDK-README] [BW-SDK-LICENSE] [BW-SDK-TERMS]. |
| D3 | Start as a modular monolith in one app target. | Keep boundaries visible without premature package or process proliferation. |
| D4 | Put mutable session state and plaintext behind one actor. | Serialize lock, unlock, sync publication, and key lifetime. |
| D5 | Persist canonical Vaultwarden ciphertext and separately AEAD-wrapped lossy Proton snapshots in SQLite behind database-level encryption. | Transactional updates without conflating provider-native records with decrypted CLI output, while protecting metadata at rest. |
| D6 | Keep decrypted projections and search indexes in memory only. | Limit plaintext persistence and make lock a deterministic state transition. |
| D7 | Ship read-first, with offline unlock/read but no offline mutation. A persisted known-rotation marker blocks offline unlock until full re-authentication. | Preserve normal offline availability without allowing a hierarchy known to be superseded; do not add an unsafe mutation queue before conflict semantics are understood. |
| D8 | For the remote server provider, test capabilities through discovery and protocol probes rather than brand or version strings. The Proton CLI is deliberately the inverse under D14: an exact tested version/build allowlist that fails closed. | Vaultwarden compatibility changes independently from official clients, while a local executable's machine-output contract is only known for versions actually tested. |
| D9 | Distribute a signed and notarized app directly first. | Keeps the first release independent from extension packaging and store review. |
| D10 | Target macOS 14 or later with Swift 6 strict concurrency. | Provides a modern native baseline while retaining both Apple Silicon and testable Intel support. |
| D11 | Generalize provider identity, capabilities, cache envelopes, and display projections only. | Vaultwarden protocol state and Proton CLI snapshots differ materially. |
| D12 | Permanently reject a Keyguard fork and exclude its source. | Its license does not grant the rights needed; VaultSquire must remain untainted and independently expressed. |
| D13 | Integrate Proton through a user-installed official CLI process. | Delegates private authentication and crypto without copying or reverse engineering Proton code. |
| D14 | Enable Proton writes per command and tested CLI version only. | A command is unavailable if any private input requires argv, environment variables, logs, or plaintext files. |

## 4. System Shape

```text
                                     +--------------+
                         URLSession  | Vaultwarden  |
                              +----->+--------------+
                              |
+-----------------------------+--+
| VaultSquire                    |
|                                |
|  SwiftUI/AppKit shell          |
|            |                   |
|  provider-neutral use cases    |
|            |                   |
|  VaultSession actor            |
|    |       |          |        |
|    |       |          +-- ProviderRegistry
|    |       |                |-- VaultwardenProvider
|    |       |                |     +-- VaultwardenCrypto
|    |       |                +-- ProtonCLIProvider
|    |       |                      +-- ProcessRunner
|    |       +-- EncryptedStore          |
|    |               |                   v
|    |               +-> SQLite     official pass-cli ----> Proton
|    +-- in-memory search           (user installed)
|                                |
|  PlatformSecurity -> Security.framework / Keychain
|  ClipboardService -> NSPasteboard
+--------------------------------+
```

This is a local modular boundary, not a microservice design. The first
implementation should remain in one app target and use folders or target-local
modules. `pass-cli` is an external user-installed process, not a VaultSquire
target or linked dependency. Separate targets are justified only for
independently sandboxed app extensions or a reusable crypto test harness.

### Components

| Component | Responsibility | Must not |
| --- | --- | --- |
| `AppShell` | Lifecycle, windows, commands, menus, dependency assembly | Parse protocol responses or retain keys |
| `Features` | Login, vault list/detail, search, settings, lock UI | Read SQLite or Keychain directly |
| `VaultSession` | App lock state, session generation, opaque provider unlock context, decrypted projections | Interpret or expose provider key material |
| `ProviderRegistry` | Resolve an account to its compiled provider and capability surface | Select behavior by marketing name in feature views |
| `VaultwardenProvider` | Environment discovery, identity, refresh, sync DTOs, mutation, error mapping | Leak wire models into generic views |
| `VaultwardenCrypto` | KDF, key unwrap, encrypt/decrypt, MAC verification, key zeroization | Perform network or persistence work |
| `ProtonCLIProvider` | CLI status/login, JSON mapping, full refresh, capability-gated commands, app cache wrapping | Implement Proton crypto/API or synthesize writes from cached JSON |
| `ProcessRunner` | Absolute-path execution, stdin/stdout streaming, bounds, timeout, cancellation | Invoke a shell or place secrets/item content in argv/environment |
| `EncryptedStore` | SQLite schema, migrations, atomic encrypted snapshot updates | Store decrypted names, usernames, URIs, notes, or search terms |
| `PlatformSecurity` | Keychain access control, biometric unlock, secure random bytes | Prompt biometrics separately from secret retrieval |
| `ClipboardService` | Copy, expiry, compare-before-clear, history-exclusion hints | Keep an unbounded copy history |

Use Swift 6 strict concurrency. UI state is `@MainActor`; `VaultSession` owns
mutable application session state and an opaque provider unlock context;
immutable `Sendable` projections cross into the UI. The Vaultwarden context owns
its user and organization keys. Introduce one small compiled provider facade and
protocols at I/O seams for tests, not one protocol per conceptual responsibility.

### Provider boundary

The first provider milestone is Vaultwarden and the second is the Proton CLI.
The boundary keeps shared app behavior from depending on Bitwarden wire shapes
or CLI JSON, not to make a runtime plug-in ecosystem.

Shared core concepts are limited to:

- provider/account/space/item compound identity;
- provider capabilities evaluated per action;
- an encrypted provider cache envelope with explicit fidelity metadata;
- a small decrypted list/detail/search projection;
- opaque provider sync state;
- common lock, clipboard, search, diagnostics, and lifecycle services.

`VaultwardenProvider` owns authentication, crypto/key graphs, DTO decoding,
unknown-field preservation, revisions/conflicts, and sync. `ProtonCLIProvider`
delegates Proton authentication, cryptography, keys, network, and remote
mutations to `pass-cli`; it owns only process safety, JSON mapping, cache
encryption, refresh publication, and capability detection. Do not define a
universal key type or assume that an item ID is globally unique, a share is a
vault, a cursor is a date, every provider has folders, or every provider supports
incremental sync.

Persistent identities include the provider account and any provider space/share
scope. A canonical projection is rebuildable. Vaultwarden writes retain
lossless native ciphertext. Proton CLI output is explicitly lossy and is never
the source for a write; each Proton write submits complete input to a documented
CLI command and refreshes afterward. The Proton-specific evidence and
non-generalization rules are in
[`PROTON_PASS_RESEARCH.md`](PROTON_PASS_RESEARCH.md).

## 5. Session And Data Model

### Orthogonal session state

Do not create one enum containing every combination. Track four coordinated
dimensions with serialized transitions:

| Dimension | States |
| --- | --- |
| Account | `noAccount`, `authenticating`, `challenged`, `authenticated`, `reauthenticationRequired`, `loggingOut` |
| Vault access | `locked`, `unlocking(sessionGeneration)`, `unlocked(sessionGeneration)`, `locking` |
| Connectivity | `offline`, `online` |
| Sync operation | `idle`, `checking`, `syncing(candidateSnapshotGeneration)`, `failed` |

"Generation" names two different things and they must not be conflated:

- **Session generation**: incremented by `VaultSession` on every unlock and every
  lock. Its only job is to discard late plaintext results. It exists only while
  unlocked.
- **Snapshot generation**: a monotonic per-account counter committed inside each
  sync transaction, identifying which complete encrypted snapshot is current. It
  survives lock and logout-free restarts, and Vaultwarden ciphertext sync
  advances it while the app is locked and no session generation exists.

The Proton "capture generation" recorded in a cache envelope is a snapshot
generation for that provider.

`VaultSession` owns the session generation, opaque provider unlock context, and
decrypted projections. `VaultwardenProvider` owns its authentication and keys;
the external CLI owns Proton authentication and keys. A normal app lock cancels
plaintext/decrypt/search work. Vaultwarden may continue ciphertext-only sync,
but Proton CLI refresh is allowed only while VaultSquire has an unlocked cache
context because CLI output is plaintext. Screen lock, sleep, logout, and account
removal cancel all sync and CLI processes.

An invalid Vaultwarden refresh token or unauthenticated CLI status moves to
`reauthenticationRequired`; it does not
silently delete a last known-good encrypted cache. A positive remote logout or
revocation signal follows its documented provider policy, locks immediately,
and may delete cached account state. Explicit user logout always deletes it.

Until the multi-account phase, an installation exposes one configured account
total, whether Vaultwarden or Proton. Persistent records are still namespaced by
provider, account, and provider space/share where applicable so adding
multi-account support does not require an identity rewrite. Workstream 10 proves
Proton as an alternative provider under that limit; concurrent Vaultwarden and
Proton accounts, aggregate lock behavior, account switching, and unified search
remain part of the later multi-account threat model and test gate.

### Persistent data

| Data | Location | Protection |
| --- | --- | --- |
| Provider kind, server base URL, and non-secret preferences | App preferences | No secret values |
| Vaultwarden access token | Memory | Refreshed as needed; never persisted |
| Vaultwarden refresh and remembered 2FA tokens | Keychain | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; never synchronizable |
| Proton CLI path and tested version | App preferences | User-approved path; no account content |
| Proton CLI session directory reference | App preferences/bookmark | Reference only; CLI owns session credentials |
| Quick-unlock key `QK` | Keychain | Access controlled as described below |
| Quick-unlock wrapped user key | Encrypted SQLite | Vaultwarden user key sealed under `QK`; never a plaintext key |
| Local database key | Keychain | Device-only and never synchronizable |
| Proton cache-envelope key | Keychain | Separate random device-only key; never synchronizable; access controlled so its post-lock release requires user presence, because it is the only gate on Proton content |
| Vaultwarden records and crypto state | Encrypted SQLite | Canonical native ciphertext plus compound IDs/revisions |
| Proton CLI snapshot | Encrypted SQLite blob | Lossy CLI JSON wrapped with VaultSquire AEAD cache key before persistence |
| Last successful snapshot generation/date | SQLite | Updated only in the same committed transaction as the snapshot |
| Decrypted list/detail projections | Memory | Owned by `VaultSession`; cleared on lock/logout |
| Search index | Memory | Incremental, rebuilt after unlock, cleared on lock/logout |

Vaultwarden ciphertext protects secret fields but not all local metadata, including
object identifiers, kinds, revision times, row counts, and access patterns.
Database-level encryption is therefore required before release as defense in
depth. It protects database contents from offline inspection but cannot hide
file size, filesystem timing, or access patterns from a live observer. The
concrete SQLite encryption mechanism and dependency must pass the Workstream 5
storage feasibility, security, and license review before adoption.

The Proton CLI returns decrypted JSON. Keep it in bounded memory, map only what
is required, and wrap any persisted snapshot with authenticated encryption under
a provider cache key retrieved from the device-only Keychain. Database-level
encryption, whose mechanism the storage spike selects, remains defense in depth;
it does not replace the per-blob wrapper. The snapshot records
CLI version, capture time, account/share scope, and `lossy: true`. Never persist
raw stdout or stderr.

Use a database per account in the final App Group container from the first
release so a later credential-provider extension does not require a container
migration. Full sync writes into one
transaction, applies deletions, records the new generation, and commits before
publishing it. A failed or cancelled sync leaves the last complete generation
usable. Database migrations are versioned and transactional.

SQLite pages, WAL, rollback journals, and temporary files must use the same
database-at-rest protection. Never materialize decrypted exports or debug dumps
in temporary files.

### In-memory projections

Do not hydrate a heavyweight decrypted object graph before showing the vault.
After unlock:

1. Read encrypted rows in a deterministic storage order. Item names are
   ciphertext, so no user-facing sort order can be computed before decryption;
   batch on a stable non-secret key such as revision date then row identifier.
2. Decrypt lightweight list projections in bounded batches.
3. Publish the first batch immediately, presented as a loading list in storage
   order rather than as a settled sort, so the user never sees rows silently
   reshuffle under a claim of alphabetical order.
4. Apply the user-facing sort as projections decrypt, inserting incrementally.
5. Build a normalized in-memory search index incrementally.
6. Decrypt full item details only when opened.

The "first 100 list rows" gate measures step 3.

Sync invalidates changed projections by identifier. It must not reload every
decrypted item or force a root-view reconstruction.

## 6. Security Design

### Threat model

VaultSquire protects against casual disk inspection, a stolen powered-off Mac,
clipboard persistence, accidental logs, maliciously malformed server data, and
dependency compromise within reasonable desktop-app controls.

It cannot protect vault plaintext from an administrator, root process,
debugger, screen reader, or compromised process while the user has the vault
unlocked. macOS may also page process memory or include it in system diagnostics,
so "memory only" is an application persistence rule rather than a guarantee
that plaintext can never reach storage. These limitations must be explicit in
security documentation.

Offline master-password unlock has no server-side attempt limiting: an attacker
with a copy of the encrypted database can test passwords at the account's KDF
cost. Resistance therefore rests on the server-selected KDF work factor and on
FileVault protecting the database and Keychain at rest. This residual is
documented rather than hidden behind a client-side attempt counter that a
direct database copy would bypass.

### Cryptographic boundary

`VaultwardenCrypto` exposes narrow operations for:

- PBKDF2 and Argon2id master-key derivation using server-provided KDF settings.
- Authentication hash derivation.
- User and organization key unwrap.
- Authenticated decryption and encryption of protocol cipher strings.
- Lightweight list projection and full item decryption.
- Constant-time authentication-tag comparison.

There is no Proton cryptographic implementation in VaultSquire. The official
CLI owns Proton account and item cryptography. VaultSquire uses only its own
versioned AEAD cache wrapper around CLI output, with a random provider cache key
stored through `PlatformSecurity`.

The initial release supports only authenticated current user-key and item
envelopes. It detects legacy unauthenticated type-0 user-key wrappers and asks
the user to migrate the account with a compatible client; it does not return
legacy unauthenticated plaintext. Any future legacy exception requires a new
security ADR and explicit fixtures.

Do not implement cryptographic primitives from scratch. Use Apple platform
cryptography where it supplies the required primitive and a reviewed,
permissively licensed Argon2 implementation for Argon2id. The exact dependency
and version require a separate review before adoption.

KDF inputs are untrusted network data. Validate algorithm identifiers, numeric
ranges, integer overflow, allocation size, and cancellation behavior while
remaining compatible with valid Vaultwarden settings. Maintain test vectors for
both PBKDF2 and Argon2id.

Swift cannot guarantee erasure of every compiler or framework copy. Still,
secret buffers should use the smallest practical lifetime, avoid unnecessary
`String` conversion, overwrite owned mutable storage on lock, and never enter
logs, crash metadata, analytics, or pasteboard history intentionally.

### Keychain and biometrics

Password unlock always remains available for Vaultwarden. Proton cached unlock
uses a VaultSquire cache key and does not replace CLI authentication.

Quick unlock uses one explicit construction rather than storing a provider key
directly:

1. Generate a random quick-unlock key `QK` when the user enables the feature.
2. Store `QK` in a generic-password Keychain item whose release is access
   controlled as described below.
3. Store an AEAD-wrapped copy of the minimum unlock material under `QK` in the
   encrypted database. The wrapper authenticates provider, account, and schema
   version.
4. Delete both records on logout, on disabling quick unlock, and whenever the
   Vaultwarden security stamp changes. Losing the database key also destroys the
   wrapped copy, so a rebuilt database starts with quick unlock disabled and the
   user re-enrolls.

Only Vaultwarden needs step 3, and the material it wraps is the user key, which
otherwise exists only as a master-password derivation. The Proton cache-envelope
key is different: it is already a random device-only key whose single
authoritative record is its own access-controlled Keychain item, so quick unlock
for Proton means reading that record under the same policy. Never keep a second
copy of the cache key wrapped in the database; one gated record is the whole
gate.

This is the one approved exception to "no live keys at rest": what persists is an
access-control-bound wrapped copy, never a plaintext key and never the master
password. The Vaultwarden master password remains an independent recovery path.

The Keychain item holding `QK`, and the Proton cache-envelope key record, are
created with:

- a `SecAccessControl` built by `SecAccessControlCreateWithFlags` with protection
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and flag `.biometryCurrentSet`
  by default. Supply the protection class to that call and attach the result as
  `kSecAttrAccessControl`; do not also set `kSecAttrAccessible` on the item,
  because the item's accessibility is already carried by the access-control
  object.
- `.userPresence` on hardware without usable biometrics, which admits the login
  password. This is the defined fallback for Intel Macs lacking Touch ID and its
  weaker semantics are disclosed in the UI rather than silently substituted.
- `kSecAttrSynchronizable` false.
- `kSecUseAuthenticationContext` with a dedicated `LAContext` and an operation
  prompt on the actual read.

The Proton cache-envelope key is access controlled for a specific reason: it is
the only gate on Proton content. VaultSquire never learns a Proton password, so
without user presence on that read any launch in an unlocked macOS session would
silently decrypt the whole Proton snapshot and Proton lock would be cosmetic.
Proton unlock is nonetheless bound to a device-local factor rather than a user
secret, which is weaker than Vaultwarden's master-password unlock; the product
says so plainly.

The Keychain read itself must authorize access. Do not first call a standalone
LocalAuthentication prompt and then perform an unrestricted Keychain lookup;
that splits authentication from secret release. A biometric enrollment change
invalidates `.biometryCurrentSet`, which destroys access to `QK` and therefore to
every copy wrapped under it. A Vaultwarden user then unlocks with the
Vaultwarden master password and may enroll again. For Proton, discard the
inaccessible local cache and refetch through the authenticated CLI; never ask
for the Proton account or Pass extra password [APPLE-KEYCHAIN] [APPLE-BIOMETRY]
[APPLE-USER-PRESENCE].

### Lock and logout

Lock performs one serialized session transition:

1. Increment the session generation and invalidate any active `LAContext`. This
   step, not task cancellation, is the actual invariant: Swift task cancellation
   is cooperative, so a task that does not check for it must still fail the
   generation check before it can publish anything.
2. Reject new decrypt and copy operations.
3. Cancel projection, search-index, and Proton CLI process tasks.
4. Clear decrypted projections, details, search terms, and owned key buffers.
5. Close sensitive sheets and replace UI state with the locked screen.
6. Clear the app-owned clipboard value if the recorded change count still
   matches, without reading the pasteboard back.

Logout additionally deletes tokens, biometric material, account preferences,
and the account database. Deletion on SSD storage is not guaranteed to erase
historical blocks; this is why persisted secret fields must already be
ciphertext.

### Network and input handling

- Require HTTPS for production accounts and use system trust evaluation.
- Support private certificate authorities installed in the user's trust store;
  do not add a global "ignore TLS errors" option.
- Normalize and validate the server URL before deriving API and identity URLs.
- Treat a discovered cross-origin identity, API, notifications, or upload
  service as a new explicitly approved allowlist entry, never as permission for
  a redirect. Approve each before creating or sending its credential.
- Bound response sizes, attachment sizes, nesting, and decoded collection
  counts before allocation.
- Treat every enum, date, identifier, URL, and encrypted string as untrusted.
- Redact authorization headers, cookies, tokens, emails, item IDs, and payloads
  from logs.
- Do not add certificate pinning; it conflicts with self-hosted deployments and
  does not replace correct trust evaluation.

### Proton CLI process boundary

- Require a user-installed official CLI; do not bundle or link it.
- Resolve a user-approved absolute path and never invoke a shell.
- Allowlist exact tested CLI versions/build identities and reject unknown
  machine-output contracts, including untested patch releases.
- Pass no secret, user-authored field value, search term, token, or credential
  material through argv or environment variables. Any opaque provider identifier
  required by a read command needs explicit command-level review.
- Stream approved write input over stdin or another reviewed protected
  non-argv, non-environment, non-filesystem machine channel.
- Treat stdout and stderr as secret-bearing, bound both, and never persist them
  raw.
- Apply timeouts and cancellation; terminate the child on lock, logout, sleep,
  session lock, or account removal.
- Materialize no private CLI request or response in any plaintext file,
  regardless of lifetime or location.
- Refresh a complete snapshot after every successful or ambiguous write.
- Test App Sandbox inheritance and CLI session/keyring access. If incompatible,
  use the reviewed direct Developer ID fallback rather than a privileged helper.

## 7. Providers And Sync

### Vaultwarden protocol boundary

VaultSquire uses the Client API implemented by Vaultwarden, not Bitwarden's
Public API. The Public API is organization-administration oriented, and the
Vault Management API is a local HTTP facade exposed by the CLI rather than a
remote personal-vault protocol [BW-PUBLIC-API] [BW-VAULT-API].

The initial compatibility target is Vaultwarden `1.37.1` and account encryption
V1. VaultSquire must detect unsupported V2 account state, retain its ciphertext,
show a clear compatibility error, and refuse mutation rather than partially
initializing or downgrading it. The application version and the protocol
compatibility value sent in `Bitwarden-Client-Version` are separate values and
advance independently after contract testing.

Protocol DTOs must:

- Decode unknown object fields without failure.
- Retain canonical raw response objects so unknown encrypted fields survive
  future read-modify-write paths.
- Represent unknown enum values instead of crashing or silently coercing them.
- Distinguish absent, null, and empty values where wire semantics differ.
- Map transport and server errors into stable application errors.
- Keep wire models out of feature views.
- For full-replacement writes, start from the latest raw object, change only
  supported fields, and preserve opaque values. Refuse the write if the endpoint
  cannot safely pass through unknown data.

Unknown cipher and encryption types remain in the encrypted store and appear as
unsupported records where possible. They are never silently dropped, rewritten,
or treated as an empty known type.

Archived state is per-user at this target: `archivedDate` is computed for the
requesting user rather than stored on the shared cipher, so archiving affects
only the acting user's view of an organization item. Treat it as a first-class
read concern from the first preview — archived items stay out of default lists
and search, behind their own filter, and are never conflated with `deletedDate`
trash state. Writes use only the dedicated archive and unarchive routes, never
`archivedDate` inside a full-object update, so a lost race can cost at most the
flag and never item content.

Capabilities come from configuration/discovery responses and successful
protocol probes. A displayed server version may aid diagnostics but must not be
the primary feature gate.

Master-password reprompt is client-enforced like collection restrictions. A
cipher marked for reprompt requires successful re-verification before reveal,
copy, edit, or autofill of any of its fields. Verification re-derives the unwrap
material from a newly entered master password and attempts to open the stored
wrapped user key. Neither quick unlock nor an already-unlocked session proves
knowledge of that password, so neither may substitute. The re-entered password
is never persisted, trimmed, normalized, or logged, and failure returns one
generic error.

### Authentication flow

P1 supports master-password login, PBKDF2, Argon2id, remembered two-factor
tokens, authenticator codes, email codes, and recovery codes with an explicit
warning. Other two-factor providers are reported as unsupported rather than
misclassified as bad credentials.

The user experience is one add-account form containing complete server URL,
email, and master password. URL/TLS/config validation runs before account-derived
material is transmitted. A 2FA challenge is a second step only when the server
returns one. "Add account" does not mean remote Vaultwarden registration in P1.

The login transaction is:

1. Validate the configured server and establish trusted HTTPS.
2. Fetch server configuration without sending the email or password-derived
   material.
3. Resolve and, when changed, obtain approval for effective API/identity origins.
4. Request prelogin KDF configuration from the approved identity origin.
5. Derive the master key and authentication hash locally.
6. Request an identity token and complete a supported two-factor challenge.
7. Decode account and crypto state, then unwrap and validate the user key.
8. Keep the access token in memory and atomically store the returned refresh
   token in Keychain only after successful response validation.
9. Fetch and transactionally persist the encrypted full sync response.
10. Publish the unlocked session and discard the master password.

On failure, clear partial account state and owned secret buffers. A network
failure after a previously completed login must not destroy the last valid
encrypted vault.

Re-authentication from `reauthenticationRequired` runs the same transaction, not
a shortened one. The account's password or keys may have been rotated while the
client was away, so re-authentication atomically replaces the stored KDF
parameters, wrapped user key, wrapped private key, and security stamp from the
login response; deletes quick-unlock material whenever the security stamp
changed, so a superseded master password cannot remain a valid offline unlock
secret; and completes a full sync before publishing decrypted views, so retained
ciphertext is never decrypted under a rotated user key. If the returned KDF
algorithm or any parameter differs from the last accepted settings for that
account, require explicit user confirmation before deriving. VaultSquire
deliberately does not try to rank cross-algorithm or mixed-parameter changes;
unchanged settings proceed without a prompt, and values below the reviewed floor
are always refused.

### Sync policy

`VaultSession` coalesces concurrent sync requests into one task. P1 triggers are:

- Immediately after first authentication.
- Explicit user refresh.
- App activation when the last revision check is stale.
- A low-frequency timer while the app is active and authenticated.

Store only server-derived revision values for revision comparison; never compare
a server revision against the Mac's wall clock. For an optimized check, request
the server revision and skip `/sync` only when it equals the last observed
server-derived revision and no force condition applies. For a full sync:

1. Read a server revision before `/sync`.
2. Fetch and validate the complete encrypted snapshot.
3. Read the server revision again.
4. If the revisions differ, discard the candidate and retry a bounded number of
   times, then retain the old snapshot and schedule another full sync.
5. If they match, commit the complete response and that server revision in one local
   transaction, then publish changed identifiers.

Manual refresh, initial login, periodic repair, and broad future notification
types force a full sync even when the coarse account revision is unchanged.
This covers server settings or organization changes that do not reliably advance
the account watermark. Keep separate last-check and last-full-sync timestamps
for scheduling only; never use them as protocol revision values.

A full sync compares candidate account bootstrap data (`userDecryption`, profile
KDF fields, wrapped keys, and security stamp) with the current snapshot before
the current-snapshot transaction. Unchanged bootstrap data commits with the
snapshot as normal. A difference means the candidate cannot be key-validated by
the current hierarchy and therefore must not become the current snapshot.

On such a difference, first reject new secret operations, increment and
invalidate the session generation if an unlocked session exists, and enter the
locked rotation transition synchronously. An already-locked sync has no live
session generation to invalidate. Only after that in-memory transition may
database or Keychain work suspend. Then atomically persist a
`reauthenticationRequired` marker while retaining the prior snapshot,
bootstrap data, and snapshot generation; invalidate quick-unlock records bound
to the previous hierarchy; and discard the candidate. Full re-authentication
obtains and validates the replacement hierarchy, fetches a fresh full sync, and
only then commits the replacement bootstrap data and snapshot together and
clears the marker. Failure, cancellation, or process death after the marker
commit leaves the prior snapshot intact and the marker set, so no late work can
publish either the old decrypted session or an unvalidated rotated snapshot. If
marker persistence itself fails, the running process remains locked and reports
a storage failure; a process killed before that durable boundary is equivalent
to a client that never observed the remote rotation.

The persisted marker prevents the previous master password from opening the
account after VaultSquire has observed a rotation, even though the retained old
snapshot remains available for transactional recovery. Before any rotation has
been observed, the previous password may still open the pre-rotation snapshot
while offline; this unavoidable stale-cache behavior is documented. A snapshot
under changed bootstrap data is never promoted or unlocked with stale key
material.

Matching before/after account revisions do not prove server-side snapshot
isolation: unwatermarked organization, policy, or settings changes can race the
multi-dataset response. Treat `/sync` as a complete best-effort response, not an
atomic database snapshot. Periodic forced sync and future broad notifications
provide eventual repair. Display snapshot age, revalidate server permissions on
mutations, and document that offline or just-synced permission state can be stale.

Polling intervals are product tuning values, not compatibility behavior. The
official client's five-minute check and six-hour full-sync threshold are
evidence, not a VaultSquire requirement.

Push notifications and targeted object refresh are a later phase. Any push
implementation must treat notifications as hints: validate revision data and
fall back to a full sync after gaps, parse errors, reconnects, or unsupported
notification kinds.

P1 has no writes. When online writes are introduced, the design must first
specify revision preconditions, conflict UI, retry idempotency, and attachment
transactions. Offline writes remain deferred; any future durable operation
queue requires a separate encrypted-storage and conflict design.

### Compatibility testing

The initial blocking CI target is the pinned Vaultwarden `1.37.1` container.
Once support expands beyond that release, black-box contract tests run against:

- The current supported release.
- The previous supported release.
- A periodically refreshed latest release lane that may be non-blocking first.

Tests create disposable accounts and verify prelogin, both KDFs, supported 2FA,
token refresh, full sync, lock/unlock persistence, unknown-field decoding, and
server error mapping. Fixtures contain generated data only, never copied
production vaults or upstream proprietary test material.

Compatibility failures should identify the endpoint and capability, not log raw
requests or encrypted payloads. Updating the matrix is a deliberate release
task whenever Vaultwarden ships.

### Proton CLI account flow

The CLI is the complete Proton integration boundary:

1. The user selects or confirms the official CLI executable.
2. VaultSquire validates the path, tested version, and machine-output support.
3. VaultSquire asks the CLI for authentication status. If login is required, it
   launches the documented CLI login flow and lets the CLI/browser collect all
   Proton credentials and second factors.
4. The provider requests vault/share and item data through documented JSON
   commands without a shell.
5. It validates bounds and schema, maps compound identities and capabilities,
   and immediately AEAD-wraps a lossy snapshot before persistence.
6. It publishes in-memory projections only for the current session generation.

The provider refreshes full CLI snapshots. It does not invent an event cursor or
offline mutation queue that the public CLI does not expose. Snapshot replacement
is atomic and retains the prior complete app-encrypted snapshot on failure.

### Proton CLI writes

Writes are capability-driven. A tested CLI command may be enabled only when:

- complete private input uses JSON/stdin or another reviewed non-argv channel;
- the command materializes no private request or response in a plaintext file;
- its result and errors can be bounded and classified;
- ambiguous completion can be followed by an authoritative full refresh;
- the operation round-trips through an official Proton client;
- the CLI version is present in the signed capability manifest.

Do not derive a write from cached or freshly fetched lossy CLI item fields. Build
complete content only from the current explicit user input. A command may also
use specifically reviewed opaque identifiers or concurrency tokens, but remains
disabled if it requires reconstructing existing item content. Current research
indicates create may become available before update because current update syntax
exposes field values in argv. Keep update disabled until a safe CLI contract
exists.

## 8. macOS Integration

### Clipboard
Copy operations are explicit and time limited. Record the pasteboard
change count when setting a secret; clear only if the change count still
matches, so a later user copy is not destroyed. Do not retain the copied
secret for value comparison: the change count alone proves ownership,
retaining the value extends plaintext lifetime, and reading the pasteboard
back re-imports clipboard content into process memory. Add recognized
transient/concealed pasteboard hints where compatible, while documenting
that third-party clipboard managers may ignore them. Clear pending values
on lock and logout [BW-CLIPBOARD].

### URI opening

P1 opens only `https` and `http` stored URIs after parsing and displaying the
effective scheme, host, and destination. It rejects credentials in the URI and
blocks `file`, `javascript`, `data`, privileged system schemes, and arbitrary
custom schemes. A later explicit user allowlist may add selected application
schemes. URI matching and autofill rules are deferred, but their eventual
implementation needs exact, base-domain, host, starts-with, regular-expression,
and never-match semantics covered by compatibility tests [BW-URI].

### Extensions

Safari Web Extensions and AuthenticationServices credential providers are
separate products with separate processes, entitlements, storage sharing, and
threat surfaces [BW-SAFARI] [BW-AUTOFILL]. Neither belongs in the first app
target.

When added, an AuthenticationServices extension opens the App Group encrypted
database read-only, never migrates or checkpoints it, and retrieves exactly one
record after Keychain-bound user presence. The main app remains the sole writer.
The extension receives no long-lived provider key and performs no network sync.
The record it reads is provider ciphertext or an AEAD-wrapped Proton blob, so
decryption needs key material: a user-presence-bound Keychain envelope releases
the minimum material for a single decryption, held only for that operation and
never cached in the extension process. That release mechanism is the core of the
extension's security design and requires its own ADR and threat model before the
extension ships; the first-release App Group decision depends only on where the
database lives, not on this mechanism being settled.
If cross-process stress tests reject this design, use an immutable encrypted
snapshot rather than an always-running broker. Current Bitwarden guidance
packages its Safari extension with the Mac App Store desktop app, so Safari
distribution and App Store constraints must be reviewed together [BW-SAFARI-HELP].

## 9. Delivery Plan

These phases restate the work that [`PLAN.md`](PLAN.md#7-detailed-work-breakdown)
sequences as Workstreams 0-11, viewed through component and data boundaries. The
plan's workstream order controls; Phase 0 ends with the headless authentication
contract slice at the start of Workstream 4, and Phase 1 completes that
workstream plus Workstreams 5-8.

### Phase 0: protocol and crypto proof

- Verified history-isolated coding context and provenance review before app code.
- Swift project with strict concurrency and secret-safe logging.
- Provider-scoped identities, capabilities, cache envelope, and fake-provider
  session/cancellation tests.
- Original AppIcon asset generation from `media-sources/icon.png`.
- Proton CLI no-shell process, sandbox inheritance, and session/keyring access
  spike with a fake executable before live CLI use.
- Server URL discovery, prelogin, PBKDF2, and Argon2id vectors.
- Cipher-string parsing, MAC validation, and generated interoperability fixtures.
- Vaultwarden container contract-test harness.
- Dependency license and supply-chain review.

Exit gate: a headless disposable-fixture harness can authenticate, download an
encrypted sync response, and decrypt known generated records independently of
the app UI. The native shell may already exist, but it is not the protocol test
oracle and account UI is not required for this gate.

### Phase 1: read-first preview

- Native login with authenticator, email, and recovery-code 2FA.
- Keychain refresh/remembered-token storage and Vaultwarden master-password
  unlock.
- Transactional, database-encrypted SQLite store.
- Login, secure note, card, identity, and SSH key list/detail views.
- Read-only organization items and enforcement of server-returned permissions.
- Preservation and safe presentation of unsupported encrypted records.
- Incremental in-memory search, folders, favorites, archived-state reads with
  their own filter, copy, manual sync, and lock.
- Auto-lock on configured inactivity, screen lock, and sleep.
- Signed and notarized direct build.

Exit gate: except after VaultSquire has durably observed a key-hierarchy rotation
that requires online re-authentication, the app remains usable from its last
encrypted snapshot while the server is unavailable. Lock removes all app-owned
decrypted state in every case.

### Phase 2: safe mutation

- Create and edit core items.
- Archive and unarchive through the dedicated per-user routes, once the
  endpoint-specific last-write-wins ADR is recorded.
- Latest-record preflight and online-only, revision-aware conflict handling.
- No blind retry of ambiguous writes and no offline mutation queue.
- Password generator and password history after threat review.

Exit gate: forced network interruption is reconciled before retry, stale edits
outside Vaultwarden's documented tolerance are detected, and the nearly
two-second race window is characterized and disclosed. Delete, restore,
favorite/partial, folder, and settings writes remain deferred because their
target routes lack the cipher stale-write precondition.

### Phase 3: Proton CLI read provider

- Official CLI discovery/selection, version policy, and status/login delegation.
- Vault/share and item JSON mapping with compound identities.
- App-level AEAD snapshot wrapping, full refresh, offline cached read, and search.
- A separate device-only, user-presence-bound Proton cache key and local cached
  unlock; no Proton key or snapshot is created during the Vaultwarden preview.
- Per-version capability manifest and secret-leakage contract tests.
- Direct Developer ID distribution fallback if App Sandbox blocks safe CLI use.

Exit gate: supported Proton records can be read, cached, unlocked, searched, and
refreshed without secrets in argv, environment variables, logs, or any plaintext
file.

### Phase 4: Proton CLI safe writes

- Enable each create/update/delete/share operation only when its documented CLI
  contract passes the stdin/protected-input gate.
- Full refresh after success or ambiguity; no offline write queue.
- Cross-client round trips, interruption tests, and automatic capability disable
  on untested CLI versions.

Exit gate: every enabled command passes the write gate; all other operations
remain explicitly unavailable.

### Phase 5: compatibility depth

- Push or server notifications with full-sync fallback.
- Attachment download/upload with whole-file authentication before release.
- Multi-account support.
- Organizations and collections beyond read-only display.
- Delete, restore, favorite/partial, folder, and settings mutations after an
  explicit last-write-wins decision and endpoint-specific race tests.
- Import/export with explicit plaintext warnings and cleanup.
- Additional two-factor and login methods.

### Phase 6: extension ecosystem

- AuthenticationServices credential provider.
- Safari Web Extension if distribution constraints are accepted.
- Passkeys, SSH agent, Send, SSO, and enterprise administration as separate
  reviewed projects.

## 10. Performance And Quality Gates

The targets below are provisional until the workstream that first implements
each scenario records a named baseline Mac, vault corpus, build configuration,
and cold/warm methodology. KDF time is reported separately because
server-selected Argon2id work is intentional.
`PLAN.md` holds the controlling copy of this table and this one mirrors it; if
they ever differ, the plan's values apply and this table is corrected.

| Scenario | Corpus | Provisional p95 gate |
| --- | --- | --- |
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

Use XCTest performance tests plus Instruments signposts around launch, KDF,
sync decode, database commit, projection decrypt, search, and lock. Signpost
metadata uses counts and durations only. Do not include account or item values.
Search computation completes off the main actor; the keystroke-to-render gate
separately measures publication and rendering on the main actor.

Required test layers:

- Unit tests for parsing, state transitions, migrations, redaction, and errors.
- Crypto vector and corruption tests, including wrong MAC before decryption.
- Vaultwarden black-box contract tests.
- Fake and live disposable-account Proton CLI contract tests, including argv,
  environment, stdout/stderr, timeout, cancellation, and version drift.
- Store crash/cancellation and migration tests.
- UI tests for login, 2FA, unlock, list/detail, copy, sync, and lock.
- Security regression tests asserting secrets do not enter logs or persisted
  search/storage records.

Telemetry is local unified logging and signposts by default. Crash reporting is
opt-in, redacted, and introduced only with a documented retention policy. Server
organization event collection is audit behavior, not permission for product
analytics.

## 11. Distribution, Licensing, And Branding

Independent VaultSquire source uses the Apache License 2.0. Every dependency
must have a recorded version, source, checksum or resolved lock entry, license,
and reason for inclusion.

The Bitwarden clients repository defaults to GPLv3, with separately restricted
code under `bitwarden_license` [BW-CLIENT-LICENSE]. The internal SDK defaults to
a choice of GPLv3 or the SDK License except for SDK `bitwarden_license`
directories. The restrictive SDK option prohibits offering, licensing, or
selling the compatible application to a third party and limits use with
non-Bitwarden implementations [BW-SDK-LICENSE] [BW-SDK-TERMS]. The SDK also
states that its password-manager interface is unsupported and unstable
[BW-SDK-README].

Therefore:

- Do not import, translate, vendor, or link Bitwarden client/internal SDK code.
- Do not copy upstream UI, strings, assets, tests, or source expression.
- Do not consult, copy, translate, or adapt Keyguard source for any VaultSquire
  implementation purpose. Its fork path is permanently rejected.
- Execute Proton's official user-installed CLI as a separate process; do not
  copy, vendor, bundle, or link Proton implementation code.
- Use independently written code, generated disposable interoperability data,
  public behavior, and protocol observations.
- Run license scanning in CI and review all crypto/runtime dependencies.
- Obtain qualified legal review before distribution, especially before any Mac
  App Store release or change in project licensing.

Bitwarden trademarks and logos are not granted by its source licenses. The
product remains named VaultSquire, uses original visual design, and mentions
compatibility only factually and secondarily. It must not imply endorsement or
use Bitwarden logos without permission [BW-TRADEMARK]. Vaultwarden likewise
states that it is not associated with Bitwarden [VW-README].

The canonical VaultSquire source artwork is `media-sources/icon.png`. Preserve
that original and generate macOS icon assets from it. Do not incorporate vendor
or third-party client logos. Proton compatibility wording and CLI path selection
must not imply that VaultSquire is an official Proton client.

Direct Developer ID distribution is required initially. App Sandbox remains a
preferred defense only if the official Proton CLI can operate with inherited
sandbox restrictions and selected session/keyring access. If not, the reviewed
fallback is a Hardened Runtime direct build with no privileged helper and a
documented minimal access boundary. Mac App Store distribution is not a target
while external CLI execution is required.

This section records engineering constraints and is not legal advice.

## 12. Open Decisions

Resolve these before scaffolding their affected phase:

| Decision | Needed by |
| --- | --- |
| Whether universal Intel support has adequate hardware/CI coverage | Public beta |
| Concrete Argon2 library and integration method | Phase 0 crypto proof |
| SQLite wrapper and database-encryption mechanism | Phase 1 / Workstream 5 storage proof |
| Whether debug builds permit explicitly configured loopback HTTP | Phase 1 login |
| Default lock timeout and sleep/screen-lock behavior | Phase 1 preview |
| Direct-update framework and signing/release service | Phase 1 distribution |
| Compatibility policy after the initial Vaultwarden 1.37.1 target | First post-preview release |
| Exact tested Proton CLI version allowlist and JSON fixtures | Phase 3 |
| App Sandbox versus direct Hardened Runtime CLI execution | Phase 0 process spike |
| First Proton CLI commands with complete stdin/protected input | Phase 4 |
| Safari packaging outside the Mac App Store | Phase 6 |

## References

All repository links below are pinned to the revisions in the evidence table.

[APPLE-BIOMETRY]: https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/biometrycurrentset
[APPLE-KEYCHAIN]: https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly
[APPLE-USER-PRESENCE]: https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/userpresence
[BW-APP-SYNC]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/src/app/app.component.ts#L423-L438
[BW-APP]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/src/app/app.component.ts#L87-L90
[BW-AUTOFILL]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/macos/autofill-extension/CredentialProviderViewController.swift
[BW-BIOMETRIC]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/src/key-management/biometrics/os-biometrics-mac.service.ts#L23-L63
[BW-CACHE]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/src/platform/main/storage/cached-backend.ts#L3-L16
[BW-CIPHER-STATE]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/vault/services/key-state/ciphers.state.ts#L17-L37
[BW-CLIENT-LICENSE]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/LICENSE.txt
[BW-CLIPBOARD]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/services/system.service.ts
[BW-CORE-SYNC]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/sync/core-sync.service.ts#L93-L218
[BW-FULL-SYNC]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/platform/sync/default-sync.service.ts#L133-L237
[BW-KEYCHAIN]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/desktop_native/core/src/password/macos.rs#L10-L35
[BW-LOGIN-SUCCESS]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/auth/src/common/services/login-success-handler/default-login-success-handler.service.ts#L19-L34
[BW-LOGIN]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/auth/src/common/login-strategies/login.strategy.ts#L118-L266
[BW-LUNR]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/vault/services/lunr-search.service.ts
[BW-MAIN]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/src/main.ts
[BW-PASSWORD-LOGIN]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/auth/src/common/login-strategies/password-login.strategy.ts#L80-L146
[BW-PRELOAD]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/src/preload.ts
[BW-PUBLIC-API]: https://bitwarden.com/help/public-api/
[BW-RUST]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/desktop_native/Cargo.toml
[BW-SAFARI-HELP]: https://bitwarden.com/help/install-safari-app-extension/
[BW-SAFARI]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/browser/src/safari/safari/SafariWebExtensionHandler.swift
[BW-SDK-LICENSE]: https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/LICENSE
[BW-SDK-README]: https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/README.md#L1-L12
[BW-SDK-TERMS]: https://github.com/bitwarden/sdk-internal/blob/4bf6b5b58f4a099e2a39ff230d5804396560aff8/LICENSE_SDK.txt#L45-L78
[BW-SEARCH]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/vault/services/search.service.ts
[BW-STORE]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/src/platform/main/storage/electron-store-backend.ts#L21-L46
[BW-SYNC-TIMER]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/src/main/messaging.main.ts#L13-L97
[BW-TRADEMARK]: https://github.com/bitwarden/server/blob/85890318551ee8a2036bfbfb3c1135b98f1a4dce/TRADEMARK_GUIDELINES.md
[BW-URI]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/libs/common/src/models/domain/domain-service.ts
[BW-VAULT-API]: https://bitwarden.com/help/bitwarden-apis.md#vault-management-api
[BW-WINDOW]: https://github.com/bitwarden/clients/blob/cfc7e4d3376127713dafa7a5924a17f4d101a05f/apps/desktop/src/main/window.main.ts
[VW-README]: https://github.com/dani-garcia/vaultwarden/blob/2629bcbe1380c894e3a7f52cafcac3988edb8fbb/README.md#L1-L55
