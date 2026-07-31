# Proton Pass Provider Research

- Status: selected provider integration evidence and constraints
- Research date: 2026-07-31
- Selected integration: official user-installed CLI process
- Latest official CLI release observed: 2.2.4, published 2026-07-31;
  untested and unsupported until its exact command contracts pass the gates
  below [PP-RELEASE-2.2.4]
- Official CLI source evidence baseline (2.2.3-era research):
  [`554fa9217c9451c3accaa52ad39d9141a9089911`](https://github.com/protonpass/pass-cli/tree/554fa9217c9451c3accaa52ad39d9141a9089911)
- Official iOS source baseline:
  [`9f0a0f6399154943c561ebcdae718da04905c007`](https://github.com/protonpass/ios-pass/tree/9f0a0f6399154943c561ebcdae718da04905c007)

This document records the evidence and safety boundaries for VaultSquire's
selected Proton Pass integration: executing the official user-installed CLI as
an external process. It distinguishes documented developer features from
behavior inferred from pinned official source. Publicly readable source is not a
compatibility contract or permission to copy it, and no Proton implementation
code, private API model, or linked library belongs in VaultSquire.

## 1. Conclusion

Proton Pass is the selected second provider after the Vaultwarden core. Reading
through the official user-installed CLI is required. Writes are a product goal,
enabled one operation and tested CLI version at a time only when complete private
input can use stdin or another reviewed protected machine channel.

The supported developer surface found in official documentation is the Proton
Pass CLI, scoped personal access tokens, agent tokens, and integrations built on
the CLI [PP-DEVELOPER] [PP-CLI-RESOURCES]. No public third-party REST API,
OpenAPI document, OAuth application registration, full client SDK, or stated
compatibility policy was found.

Binding integration policy:

1. Build `ProtonCLIProvider` only after the shared shell, lock, storage, and
   search foundations are proven by the Vaultwarden provider.
2. Delegate Proton login, session refresh, cryptography, keys, and network
   traffic to the official CLI. Do not implement the private Proton protocol.
3. Require CLI reads through a tested machine-readable command contract and fail
   closed on unsupported versions or output schemas.
4. Treat CLI JSON as decrypted and lossy. Immediately wrap every persisted
   snapshot with VaultSquire AEAD under a device-only Keychain key; never call it
   Proton-native ciphertext.
5. Never synthesize a write from the lossy snapshot. Enable a write only when
   the exact tested command accepts all private input outside argv, environment
   variables, logs, and every plaintext file, then refresh after success or
   ambiguity.
6. Keep Proton source code and internal packages outside the product. The user
   installs the official CLI; VaultSquire does not copy, bundle, vendor, or link
   it.
7. Complete terms, support-risk, client-identification, and trademark review
   before general availability. A partner contract or stable machine API would
   improve supportability but is not a reason to reverse engineer a private API.

## 2. Evidence Classification

| Label | Meaning |
|---|---|
| Documented | Proton product, developer, or CLI documentation states it |
| Source-derived | Pinned official source exhibits the behavior |
| Assessment | VaultSquire engineering recommendation or risk conclusion |
| Unknown | No stable public statement was found |

Every source-derived observation must be revalidated before it affects a tested
CLI command contract. Private protocol details in this report explain why the
CLI boundary exists; they are not models to implement in VaultSquire.

## 3. Supported Integration Surface

### Documented Features

Proton's developer page advertises:

- the Proton Pass CLI;
- personal access tokens scoped to vaults or items;
- AI agent access tokens with scope, expiration, and access logs;
- Ansible and GitHub Actions integrations built on the CLI.

The CLI is documented for Intel and Apple Silicon macOS, Linux, and Windows
[PP-INSTALL]. Proton describes item and vault management through the CLI, but
does not describe the CLI as a stable GUI backend or publish versioned JSON
schemas for third-party clients.

### Surfaces Not Found

The research did not find a documented public surface for:

- native third-party interactive client registration;
- a supported embeddable Swift, Kotlin, Rust, or C SDK;
- a public REST base URL and endpoint contract;
- OpenAPI or generated client definitions;
- long-lived event cursor semantics for external clients;
- key rotation and conflict guarantees for third parties;
- a compatibility support window;
- a Proton review or certification program for third-party clients.

This is an absence finding. Private, partner, or future interfaces may exist.

### Official Source Is Not A Public SDK

The CLI workspace contains reusable Rust crates and can emit library forms, but
Proton does not present those crates as a supported SDK. The workspace relies on
packages from Proton's own Cargo registry, including `muon` and Proton crypto
components [PP-CARGO]. The CLI contribution policy says the repository is not
open to external contributions [PP-CONTRIBUTING].

These facts increase maintenance and supply-chain risk even when the visible
code is technically reusable.

## 4. Authentication And Session Model

### Documented CLI Login Modes

The CLI supports:

| Mode | Intended use | Relevant constraints |
|---|---|---|
| Browser login | Normal interactive account | Handles advanced account flows in browser |
| Terminal login | Interactive terminal | Account password, TOTP, optional Pass extra password |
| Personal access token | Automation | Scoped, expiring access with viewer/editor/manager grants |
| Agent token | AI automation | Scoped access with audit behavior |

FIDO-only and SSO accounts use browser login according to current CLI
documentation [PP-LOGIN].

### Source-Derived Session Flow

At the pinned CLI revision:

- interactive login delegates primary Proton authentication to `muon` and
  handles TOTP [PP-INTERACTIVE-AUTH];
- browser login creates a session fork, opens an account URL, polls for
  completion, and decrypts returned key-password material [PP-WEB-AUTH];
- the optional Proton Pass extra password uses a separate SRP exchange to gain
  Pass scope [PP-EXTRA-PASSWORD];
- access and refresh credentials are encrypted before local persistence
  [PP-SESSION-STORE];
- PAT login receives scoped session credentials plus PAT key material
  [PP-PAT-AUTH];
- PAT and agent sessions cannot perform ordinary user-key operations
  [PP-USER-KEYS].

An independent native implementation would need to own all of these flows and
their future changes. A CLI adapter should own none of them: it may invoke a
documented CLI login flow, but the CLI/browser collects all credentials and the
CLI manages refresh and local credential persistence.

## 5. Provider-Native Data Model

### Identity And Scope

A Proton `Share` represents a user's access relationship to a resource. It is
not safely interchangeable with "vault." Different recipients can have
different share IDs for access to the same underlying vault [PP-SHARE].

Required local identity shape:

```text
ProviderAccountID
ProviderShareID
ProviderVaultID, when present
ProviderItemKey = ProviderAccountID + ProviderShareID + ProviderItemID
```

No public global uniqueness guarantee for `ItemID` was found. Commands and key
resolution commonly use share scope, so VaultSquire must defensively use the
compound identity and retain both the access relationship and underlying
resource identity where available.

### Items And States

The pinned official item content definitions include:

- login;
- note;
- alias;
- credit card;
- identity;
- SSH key;
- Wi-Fi;
- custom item.

This list is source-derived from the pinned item schema [PP-PROTO] and must be
validated against the tested CLI's actual machine output.

Passkeys are embedded in login content, not independent vault records. The alias
protobuf content is empty [PP-PROTO], so alias behavior cannot be reconstructed
from the encrypted item content alone and needs separately researched
provider-specific server operations.

Assessment: model active, trashed, permanently deleted, and missing-from-scope as
distinct states unless tested CLI fixtures prove a narrower contract. Do not
collapse those outcomes into one boolean based on naming alone.

### Vaults, Folders, Sharing, And Roles

The following are source-derived model observations, not a CLI compatibility
promise:

- Items belong to one vault and may be in nested folders.
- Folder keys participate in the cryptographic hierarchy.
- Shares can represent vault or individual-item access.
- Role names include owner, manager, editor, and viewer, but their exact powers
  are provider and resource specific.
- Cross-vault movement can require migration and re-encryption rather than a
  local folder-ID update.

Sources: share scope [PP-SHARE], cryptographic hierarchy [PP-CRYPTO], and item
creation behavior [PP-ITEM-CREATE]. Each supported UI action still requires a
black-box CLI fixture.

The generic UI may display spaces and capabilities, but the official CLI's
semantics and the tested command capability manifest control authorization and
mutation.

## 6. Cryptographic Model

### Documented Security Description

Proton documents 32-byte vault keys, AES-256-GCM encrypted vault content,
encrypted metadata, and OpenPGP Curve25519 key protection and sharing
[PP-SECURITY].

### Source-Derived Hierarchy

The pinned official sources indicate this broad hierarchy:

1. Proton account credentials unlock user OpenPGP keys.
2. User, address, or group keys decrypt and verify share keys.
3. Share and vault content uses AES-256-GCM with purpose-specific associated
   data tags.
4. Nested folder keys are wrapped by a parent folder or share key.
5. Each item receives a random 32-byte item key.
6. Protobuf item content is encrypted with that item key.
7. The item key is wrapped by the applicable share or folder key.
8. Attachment keys are wrapped by item keys, with distinct authenticated tags
   for file data and metadata.

Sources: encryption contexts and tags [PP-CRYPTO], item creation
[PP-ITEM-CREATE], and share-key opening [PP-SHARE-KEY].

This cannot be represented as a generic "decrypt item with account key"
interface without losing rotation, hierarchy, and associated-data invariants.
The official CLI, not `ProtonCLIProvider`, owns this key graph. VaultSquire sees
only bounded machine output, a lossy app-encrypted cache snapshot, and approved
decrypted projections while unlocked.

### Security Consequence

Implementing this from source observation alone would create a high-risk private
protocol dependency. A small error could expose records, fail key verification,
lose unknown protobuf fields, corrupt rotations, or create content official
clients cannot open. VaultSquire therefore delegates this entire boundary to the
official CLI and tests only the external command contract and its own cache
wrapper.

## 7. Sync And Conflict Model

### Source-Derived Full Sync

The pinned iOS client performs a full refresh by updating account data,
rebuilding shares, fetching folders/items, replacing local share content, and
establishing event state [PP-IOS-FULL-SYNC] [PP-IOS-ITEM-REPLACE]. The exact
ordering has changed relative to older comments, which is evidence that source
behavior is not a stable external protocol.

### Incremental Behavior

Official source models include the following source-derived concepts; they are
not a public CLI contract and require independent fixture validation:

- opaque event IDs and pagination tokens;
- user and share event streams;
- pending-event indicators;
- updated and deleted items;
- key rotation events;
- server-requested full refresh;
- item revisions and `LastRevision` write preconditions.

The pinned full-sync and replacement paths demonstrate that this state evolves
inside official clients [PP-IOS-FULL-SYNC] [PP-IOS-ITEM-REPLACE].

A hypothetical native implementation would have to store an event cursor as an
opaque provider value scoped exactly as returned, without parsing it as a
timestamp or incrementing it. `ProtonCLIProvider` does not invent or persist a
cursor the public CLI does not expose.

### Why VaultSquire Does Not Implement Native Sync

A hypothetical native provider would need to prove:

- initial snapshot and event cursor establish a race-free boundary;
- duplicate and reordered events converge;
- cursor persistence and item commits are crash consistent;
- server-requested full refresh cannot mix old and new key generations;
- key rotations are applied before content that requires them;
- an interrupted stale write is reconciled before retry;
- full refresh preserves pending local work or explicitly rejects offline edits;
- unknown protobuf fields survive read-modify-write.

The public CLI does not expose enough of this contract for a local-first sync
engine. `ProtonCLIProvider` therefore performs full CLI refreshes, publishes a
validated app-encrypted snapshot atomically, and never creates an offline write
queue. A remote write is allowed only through an independently tested official
CLI command and is always followed by a full refresh.

## 8. CLI Capability Assessment

| Capability | Public CLI suitability for VaultSquire |
|---|---|
| Browser/TOTP/advanced login | Good when the CLI owns the session |
| Vault and item listing | Required after versioned JSON/schema contract tests |
| Secret item viewing | Required with bounded transient stdout and no raw persistence/logging |
| Core item creation | Candidate only where complete JSON/stdin input passes the write gate |
| Item update | Disabled while private field values are command arguments |
| Trash/permanent delete | Candidate only after exact semantics and ambiguous-result tests; the documented `item delete` is described as permanent and irreversible, so it must never be presented with Vaultwarden's reversible-trash wording |
| Archive/unarchive | No archive command found in the documented item surface. The action is absent for Proton accounts and must not be mapped onto trash, deletion, or a favorite [PP-ITEM-COMMANDS] |
| Folders | Incomplete public machine surface for full fidelity |
| Aliases | Partial; many operations remain provider-specific |
| Attachments | Public command surface is primarily download-oriented |
| Passkeys | Data may be visible; complete native registration/autofill is absent |
| Event cursor/incremental sync | Not documented for external use |
| Native AutoFill | VaultSquire would need its own encrypted cache and extension |
| Offline read | Supported only from a VaultSquire AEAD-wrapped lossy snapshot |
| Offline write | Unsupported without a tested CLI conflict/revision contract |
| Stable JSON contract | No explicit promise; pin versions and fail closed |

The current update command accepts values such as password through command-line
arguments and cannot update every field category [PP-ITEM-UPDATE]. Same-user
process inspection, shell history, diagnostics, and crash tooling can expose
argv. VaultSquire must not use this path for secret writes. The documented create
path is the contrast that makes gating worthwhile: it accepts a JSON template on
standard input, which is the shape the write gate requires [PP-ITEM-COMMANDS].

Capability gaps are surfaced, never papered over. The documented item surface
exposes no archive operation, so a VaultSquire archive action does not exist for
Proton accounts. Presenting Proton's permanent deletion as an archive or a trash
would misrepresent an irreversible operation as a reversible one.

### Current Command-Surface Observations

Verified against the pinned 2.2.3-era command documentation [PP-ITEM-UPDATE];
revalidate against each tested CLI version before use:

- `item update --field FIELD_NAME=FIELD_VALUE` places field values, including
  passwords, in argv: update stays disabled. The same documentation states
  update cannot modify TOTP or time fields, so capability manifests record
  per-field capability, not only per-command availability.
- `item create login --from-template -` accepts a JSON template over stdin and
  is the primary create candidate. The same command offers `--password`,
  `--title`, `--username`, `--email`, and `--url` argv options; VaultSquire
  must never pass user data through them.
- `item list` accepts a positional `VAULT_NAME` and `--vault-name`, and
  `item view` accepts `--vault-name`, `--item-title`, and a `pass://` URI that
  may embed vault and item names: all place user-chosen names in argv and must
  not be used. Selection uses only reviewed opaque identifiers (`--share-id`,
  `--item-id`, or the equivalent `pass://SHARE_ID/ITEM_ID` form), each still
  subject to the command-level argv review because identifiers are
  process-visible.
- `item view` with a field selector or `?totp=uri` prints secrets to stdout;
  the bounded transient-buffer and no-raw-persistence rules apply unchanged.

## 9. Integration Route Comparison

| Route | Fidelity | Stability | License/distribution | Recommendation |
|---|---|---|---|---|
| User-installed CLI subprocess | Read-heavy subset plus gated commands | CLI supported, embedding/JSON not promised | Cleanest separation; still review terms | Selected route |
| Bundled unmodified CLI helper | Same subset | Same contract risk | GPL source/distribution, signing, updater obligations | Do not use |
| Link official Rust/Swift code | Potentially high | Internal packages, not SDK | Would require a different licensing and architecture decision | Do not use |
| Independent private API | Potentially high | Highest drift and crypto risk | Terms/schema/trademark uncertainty | Do not use |
| Proton partner API/SDK | Potentially high | Could be supportable | Requires agreement | Reassess only if officially offered |

The selected CLI route does not become a private API fallback when one command
is inadequate. Reads or individual writes remain unavailable until the official
CLI exposes a contract that satisfies their gate.

## 10. VaultSquire Architecture Seams

### Generic Core Types

The core may know:

| Type | Required semantics |
|---|---|
| Provider kind | Stable local identifier, not a remote marketing string |
| Account reference | Opaque provider account ID and display metadata |
| Space reference | Opaque account-scoped access/container identity |
| Record reference | Opaque account + space/share + record identity |
| Record projection | Display/search fields plus exact capabilities |
| Cache envelope | Fidelity-labelled provider state encrypted at rest; Proton snapshots are lossy |
| Sync state | Opaque provider scope, cursor kind/value, and generation |
| Capability set | Explicit per account/space/record/action support |

### CLI And Adapter Ownership

The official CLI owns:

- login methods, challenges, refresh, and Proton credential persistence;
- key loading, verification, wrapping, rotation, and destruction;
- private API/protobuf decoding and server communication;
- provider-native snapshot, event, revision, and conflict behavior;
- item, folder, alias, sharing, attachment, and passkey operations.

`ProtonCLIProvider` owns only:

- executable selection, tested-version checks, and command capability manifests;
- no-shell process execution, bounds, cancellation, and safe error mapping;
- validation and mapping of documented machine output into compound identities
  and a deliberately small canonical display projection;
- immediate AEAD wrapping and atomic publication of lossy cache snapshots;
- full refresh, stale-state presentation, and post-write reconciliation;
- capability calculation for every action from the exact tested CLI contract.

### Core-Owned Services

The application core owns:

- macOS lifecycle and lock triggers;
- database lifecycle and at-rest encryption;
- account namespace and provider registry;
- navigation and generic list/detail surfaces;
- search over approved projection fields;
- clipboard, reveal, URI opening, and accessibility policy;
- diagnostics allowlist and performance instrumentation;
- release, migration, and extension compatibility.

### Capability Design

Use exact capabilities rather than a provider-name switch. Candidate values
include:

- read, reveal, copy username, copy password, copy TOTP;
- create, edit, trash, restore, permanent delete;
- move within space, move across spaces, organize in folders;
- pin/favorite, archive;
- list/download/upload/delete attachments;
- create/manage alias;
- share item, share vault, manage members;
- use/register passkey;
- offline read, offline write, incremental sync.

Capabilities can vary by account, space, item, role, policy, and current
connectivity. UI checks are not sufficient; use cases must enforce them again.

### Cache Fidelity Rule

CLI JSON is decrypted output and is not a provider-native encrypted envelope. A
persisted Proton snapshot must:

- be validated and immediately wrapped with VaultSquire AEAD under a random
  device-only Keychain key before database persistence;
- authenticate provider account/scope, CLI version, schema version, capture
  generation, timestamp, and `lossy: true` metadata;
- retain only the bounded fields required for supported display, search, and
  explicit offline read behavior;
- keep raw stdout and stderr out of the database, logs, diagnostics, crash
  reports, and support bundles;
- be atomically replaced only after a complete refresh validates;
- never be described as Proton end-to-end ciphertext or used to reconstruct,
  merge, or retry a remote write.

A write never uses cached or freshly fetched lossy CLI item fields. Its content
comes from current explicit user input; only specifically reviewed opaque
identifiers or concurrency tokens may be added from CLI output. A command that
requires reconstructing existing item content remains disabled. After success
or ambiguity, VaultSquire refreshes from the CLI rather than mutating the cache
locally.

## 11. What Must Not Be Generalized

Do not encode these assumptions in the core:

- every provider uses OAuth;
- account 2FA is the same as a Pass extra password;
- one item ID is globally unique;
- a share is a vault;
- a vault is an organization;
- roles with the same English name grant the same actions;
- folders are optional labels rather than key-bearing hierarchy nodes;
- favorite, pin, archive, trash, and deletion are interchangeable;
- a passkey is a standalone record;
- alias fields are ordinary encrypted item fields;
- every provider exposes full snapshots or incremental events;
- every cursor is a number or date;
- every write has a revision, or revisions have the same type;
- all encrypted content maps losslessly into one item union;
- all providers permit offline writes;
- all providers share KDF, key, cipher, or attachment algorithms.

Generalize stable application needs: identity namespace, capabilities, cache
envelopes with explicit fidelity, display projections, lock lifecycle, encrypted storage, search,
clipboard, diagnostics, and release policy.

## 12. Selected CLI Provider Plan

### Preconditions

- A standalone unpublished harness establishes the exact process and JSON
  contracts before they enter the application.
- The user installs the official CLI; VaultSquire does not bundle it.
- The CLI or browser collects every Proton credential and second factor.
  VaultSquire may launch a documented login flow but never proxies those values.
- Only disposable test accounts are used during development.
- Read capability ships only for declared tested versions. Every write starts
  disabled and is enabled by an operation-specific signed capability manifest.

### Process Boundary

- Prove the command contract in a standalone harness before placing it in
  VaultSquire.
- Run a separate App Sandbox feasibility spike. A user-installed executable and
  its external session/keyring directories may be inaccessible or inherit a
  sandbox that prevents normal CLI operation. If so, use the reviewed direct
  Developer ID Hardened Runtime fallback with minimal access, no privileged
  helper, and no Mac App Store target.
- Resolve an allowlisted absolute binary path.
- Obtain user-selected security-scoped access where required. Inspect code
  signature/team identity when present and show the chosen path; version output
  alone does not authenticate the executable. Resolve symlinks before approval
  and record the real path. Record signature and notarization status honestly,
  including an explicit ad-hoc or unsigned marker when the package manager
  build is not Developer ID signed.
- Never invoke a shell.
- Require an explicit allowlist of exact tested versions/build identities and
  command schemas. Every unlisted patch release is unsupported until tested.
- Use a documented CLI session arrangement per VaultSquire account without
  copying credentials or exposing private session material through argv or
  environment variables. Select the session only through a reviewed non-secret
  mechanism the tested CLI documents (such as an absolute session-path
  argument). Never relocate the CLI through `HOME` or `XDG_*` environment
  overrides: that redirects the CLI's whole configuration and credential
  stores, and the environment channel is prohibited for session material.
- Interactive terminal login requires a TTY that VaultSquire does not own.
  Never allocate a pseudo-terminal or pipe Proton credentials to the CLI; use
  the documented browser login flow or direct the user to their own terminal.
  The Phase 0 spike must prove status detection and login launch without any
  credential capture.
- Serialize commands per account.
- Bound stdin/stdout/stderr sizes and execution time.
- Cancel and terminate work on lock or account removal.
- Parse stdout as untrusted data; treat stderr as secret-bearing and do not
  persist either raw.
- Never put a search term, secret, token, user-authored field, item content, or
  credential material in argv or environment variables. Any opaque identifier
  required for a read command needs explicit command-level review.
- Disable core dumps and support-bundle process dumps for the helper path.

### Data Flow

1. Verify binary version and authenticated status.
2. Fetch account and accessible-space metadata.
3. Fetch item summaries, then required full item content.
4. Construct compound account/share/item identities.
5. Treat CLI JSON as a versioned, lossy `CliSnapshot`, not a provider-native
   encrypted envelope. No versioned round-trip schema promises that it retains
   encrypted protobuf bytes, key rotations, complete revisions, or unknown
   fields required for safe writes; do not infer such fidelity without a new
   documented contract and fixtures.
6. Immediately wrap a complete validated snapshot in a VaultSquire AEAD cache
   envelope under a device-only Keychain key before persistence.
7. Publish the new cache generation atomically and retain the prior complete
   generation on failure or cancellation.
8. Build and search an in-memory projection; do not invoke the CLI per keystroke.
9. Fetch from the CLI only on explicit refresh or an approved on-demand path,
   and only while the VaultSquire cache context is unlocked.

### Write Capability Flow

For each operation and CLI version independently:

1. Record the exact command, machine input/output schema, side effects, and
   ambiguity behavior in the capability manifest.
2. Require complete private input over stdin or another reviewed protected
   machine channel. Reject argv, environment, logs, and every plaintext file.
3. Build content only from the current explicit user action. Permit CLI output
   only for specifically reviewed opaque identifiers or concurrency tokens;
   never reuse cached or freshly fetched lossy item fields.
4. Bound input, output, stderr, duration, and decoded structure; serialize
   commands per account.
5. After success or an ambiguous result, run a full authoritative CLI refresh
   before presenting final state or allowing a retry.
6. Cross-read every successful synthetic mutation with an official Proton
   client.
7. Automatically disable the capability when the executable identity, version,
   schema, or command contract does not match.

Current research shows update syntax that places private field values in argv,
so update remains disabled. Create or other operations may ship earlier only if
the pinned CLI's complete JSON/stdin contract passes every gate above.

### Read Exit Criteria

- Login, note, card, identity, SSH, alias, Wi-Fi, and custom records either map
  faithfully within the CLI's exposed fields or show explicit unsupported
  status. No safe round-trip claim is made.
- Duplicate names and same item IDs in different shares do not collide.
- The app-encrypted cache supports offline unlock/read without claiming Proton
  native ciphertext, master-password unlock, or offline mutation.
- 10,000-item refresh, cached launch, unlock, and local search meet agreed
  budgets.
- Missing binary, wrong version, unauthenticated session, expired session,
  malformed JSON, timeout, cancellation, and nonzero exit are recoverable.
- Fixture secrets never appear in argv, environment variables, logs, raw stderr
  persistence, diagnostics, crash metadata, support bundles, or unencrypted
  files.
- App Sandbox works safely or the direct Developer ID fallback passes its clean
  Mac and minimal-access review.

## 13. Production Contract And Outreach Questions

Ask Proton to answer in writing:

- Is a third-party interactive Proton Pass client supported?
- Is there a partner API, SDK, or planned versioned CLI RPC mode?
- How must a client identify itself and handle rate limits?
- Which login modes may third parties implement?
- What event, cursor, revision, and key-rotation behavior is contractual?
- Which protobuf definitions and generated bindings may be redistributed?
- May official Rust/Swift packages be embedded on macOS, and under what license?
- Are Personal Access Tokens suitable for interactive user vaults?
- Can the CLI offer secret input over stdin or protected IPC rather than argv?
- Can the CLI expose a stable JSON schema, folders, revisions, events, and safe
  attachment upload?
- What branding and compatibility wording is allowed?
- What support window and deprecation notice can a third-party client rely on?

The selected external CLI provider does not require VaultSquire to build Proton
components. Production read support stops if the official CLI cannot be
identified and executed safely, no tested machine-readable read contract exists,
terms review rejects the integration, or neither App Sandbox nor the reviewed
direct-build fallback can support the CLI session boundary. A write operation
stays disabled when its input, conflict, ambiguity, or cross-client behavior
cannot be tested safely; that does not redirect VaultSquire to a private API.

## 14. Licensing, Terms, And Branding

This is engineering guidance, not legal advice.

- The CLI, Proton Pass common code, Android client, and iOS client reviewed are
  GPLv3 or GPLv3-or-later at the pinned revisions [PP-CLI-LICENSE]
  [PP-COMMON-LICENSE] [PP-ANDROID-LICENSE] [PP-IOS-LICENSE].
- Linking or adapting those implementations generally requires a GPL-compatible
  distribution decision and corresponding source obligations.
- A separate user-installed CLI process reduces code-license coupling, but does
  not answer service terms or API support questions.
- VaultSquire does not redistribute the CLI. Bundling it would create a separate
  license, signing, update, and source-offer decision and is outside the selected
  architecture.
- The CLI's internal dependency graph includes packages not presented as public
  supported SDKs.
- A standalone item protobuf repository did not expose a clear license during
  research; do not copy it without clarification.
- Proton's Terms, last modified 2026-06-23 when captured, address automation
  that is distinguishable from standard client behavior, significantly deviates
  from normal use, exhibits characteristics of abuse, or attempts to circumvent
  security controls. They reserve the right to restrict such access, restrict
  making services available to third parties in some circumstances, and grant
  no trademark license [PP-TERMS]. Whether a specific compatibility client
  triggers those clauses requires product-specific legal review.
- GPL does not grant Proton trademark rights.

Use original VaultSquire branding and factual compatibility wording only after
the project's Proton outreach and legal review. Do not use Proton logos or imply
affiliation. This is a conservative product policy, not a conclusion that all
factual compatibility references require prior trademark permission.

## 15. Final Recommendation

Implement Vaultwarden first, then add `ProtonCLIProvider` as the selected second
provider. It executes an official user-installed CLI and contains no Proton API
models, cryptography, copied/linked code, fake OAuth abstraction, or empty
private-protocol tables.

Proton reads are required after the version, process, schema, cache, lock,
distribution, leakage, and performance gates pass. Writes are capability-gated
per command: safe create may precede update, and any command requiring private
values in argv, environment variables, logs, or any plaintext file remains
unavailable. Every successful or ambiguous mutation is followed by a full CLI
refresh and every successful synthetic write is cross-read by an official
Proton client.

Continue Proton outreach and legal/support review before general availability,
but do not reverse engineer a private API while waiting for a stronger official
contract. If the CLI cannot expose a safe operation, VaultSquire presents that
operation as unsupported.

## References

All links were accessed on 2026-07-31. No archive or content hash was captured
for mutable Proton web pages, so their exact historical state is not
reproducible from this repository. Treat claims based on those pages as unpinned
paraphrases and recheck the pages, modification date, and terms before use.

[PP-ANDROID-LICENSE]: https://github.com/protonpass/android-pass/blob/cb4bc258f5b3e4091548a66215f3d23e3506366e/LICENSE
[PP-CARGO]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/Cargo.toml#L13-L20
[PP-CLI-LICENSE]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/README.md#license
[PP-CLI-RESOURCES]: https://protonpass.github.io/pass-cli/developer-resources/
[PP-COMMON-LICENSE]: https://github.com/protonpass/proton-pass-common/blob/65bb8448a41098686c9305265d2312c79d4dcef8/LICENSE
[PP-CONTRIBUTING]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/CONTRIBUTING.md
[PP-CRYPTO]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/pass-domain/src/crypto.rs#L20-L123
[PP-DEVELOPER]: https://proton.me/pass/developer-features
[PP-EXTRA-PASSWORD]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/pass-auth/src/extra_password.rs#L30-L128
[PP-INSTALL]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/docs/public/docs/get-started/installation.md
[PP-INTERACTIVE-AUTH]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/pass-auth/src/interactive_login.rs#L37-L107
[PP-IOS-FULL-SYNC]: https://github.com/protonpass/ios-pass/blob/9f0a0f6399154943c561ebcdae718da04905c007/iOS/Shared/Data/Managers/AppContentManager.swift#L177-L250
[PP-IOS-ITEM-REPLACE]: https://github.com/protonpass/ios-pass/blob/9f0a0f6399154943c561ebcdae718da04905c007/LocalPackages/Client/Sources/Client/Repositories/ItemRepository.swift#L340-L389
[PP-IOS-LICENSE]: https://github.com/protonpass/ios-pass/blob/9f0a0f6399154943c561ebcdae718da04905c007/LICENSE
[PP-ITEM-COMMANDS]: https://protonpass.github.io/pass-cli/commands/item/
[PP-ITEM-CREATE]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/pass/src/item/create/common.rs#L68-L147
[PP-ITEM-UPDATE]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/docs/public/docs/commands/item.md#update
[PP-LOGIN]: https://protonpass.github.io/pass-cli/commands/login/
[PP-PAT-AUTH]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/pass-auth/src/personal_access_token.rs#L121-L201
[PP-PROTO]: https://github.com/protonpass/pass-contents-proto-definition/blob/8c88394ed97752e4a8c00cb2e1c4e495bd9a505b/protos/item_v1.proto#L9-L237
[PP-RELEASE-2.2.4]: https://github.com/protonpass/pass-cli/releases/tag/2.2.4
[PP-SECURITY]: https://proton.me/pass/security
[PP-SESSION-STORE]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/pass-auth/src/store.rs#L322-L421
[PP-SHARE]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/docs/public/docs/objects/share.md
[PP-SHARE-KEY]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/pass/src/crypto/share_key.rs#L25-L76
[PP-TERMS]: https://proton.me/legal/terms
[PP-USER-KEYS]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/pass/src/user_keys.rs#L27-L63
[PP-WEB-AUTH]: https://github.com/protonpass/pass-cli/blob/554fa9217c9451c3accaa52ad39d9141a9089911/pass-auth/src/web_login.rs#L145-L315
