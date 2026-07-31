# VaultSquire Security And Verification Plan

- Status: normative security plan
- Last updated: 2026-07-31
- Applies to: application, providers, local storage, extensions, build, and release

VaultSquire is a password manager. Correct UI behavior is not sufficient: a
release must preserve authentication, cryptographic, storage, sync, permission,
and lifecycle invariants under malicious input, cancellation, process death,
network ambiguity, and local observation.

This plan complements [`ARCHITECTURE.md`](ARCHITECTURE.md) and the pinned
Vaultwarden scenarios in
[`IMPLEMENTATION_REPORT.md`](IMPLEMENTATION_REPORT.md#compatibility-test-matrix).

## 1. Security Objectives

### Required Properties

- A Vaultwarden master password is never persisted or sent to the server as
  plaintext. VaultSquire never asks for or captures a Proton account password;
  the official CLI/browser owns Proton login.
- Vaultwarden cryptography is interoperable with a pinned reference and fails
  closed on unknown algorithms, malformed values, and failed authentication.
- VaultSquire contains no Keyguard code or source-derived implementation detail
  and no copied/linked Proton implementation code.
- Every Proton CLI process has a tested command contract, bounded I/O,
  cancellation, and no secret or item content in argv or environment variables.
- A failed or cancelled sync cannot replace the last complete encrypted vault.
- No intended plaintext vault content is written to database pages, journals,
  temporary files, preferences, logs, diagnostics, state restoration, or search
  indexes.
- Device theft without the logged-in user session does not expose cached vault
  content or reusable session credentials.
- Lock removes all application-owned decrypted state that can be deterministically
  released and prevents late asynchronous publication.
- Logout removes account credentials and local account storage.
- Server permissions and item restrictions are enforced by use cases, not only
  by disabled buttons.
- Network credentials are sent only to a service origin explicitly allowlisted
  before that credential is created. Redirects never expand the allowlist, and
  each identity, API, notification, and upload credential is scoped to its
  approved role/origin.
- Writes cannot overwrite a concurrent edit already known to the client. Any
  provider race the server cannot guard is documented and deferred or accepted
  explicitly before that mutation ships.
- Release artifacts are traceable to reviewed source and have inspected
  entitlements, signatures, notarization, dependency inventory, and provenance.

### Explicit Non-Guarantees

VaultSquire cannot protect an unlocked vault from:

- root, kernel, hypervisor, debugger, or equivalent endpoint compromise;
- malware with sufficient same-user, accessibility, screen-recording, or
  process-injection access;
- a camera, screen share, or a person observing the screen;
- a clipboard manager that reads a secret before its expiration;
- all runtime/compiler copies of immutable Swift values;
- server omission, denial of service, or replay where the provider protocol does
  not cryptographically bind freshness;
- complete filesystem access-pattern or file-size observation;
- offline organization revocation before the next successful sync.

The product must state these limits honestly. "Memory only," "encrypted," and
"clipboard expires" must not be marketed as absolute exfiltration prevention.

## 2. Assets

| Asset | Sensitivity | Required handling |
|---|---|---|
| Vaultwarden master password | Critical | Shortest possible lifetime; never persist, log, normalize, or transmit raw |
| Derived master/auth keys | Critical | Actor-confined mutable buffers; destroy on failure/lock |
| User, organization, item, attachment keys | Critical | Unlocked session only; never cross into view state |
| Refresh/remember tokens | Critical | Device-only Keychain; atomic replacement; remove on logout |
| Access token | High | Memory only; redact URL/query/header uses |
| TOTP/recovery/2FA proof | Critical | One operation; no clipboard/history/logging |
| Decrypted vault records | Critical | Bounded in-memory projections; no state restoration |
| Vaultwarden provider ciphertext | High | Encrypted local database because metadata remains sensitive |
| Proton CLI stdout/stderr | Critical | Bounded transient memory; never persist raw or include in errors |
| Proton CLI cache snapshot | Critical | Mark lossy; VaultSquire AEAD wrapper plus encrypted database |
| Proton CLI executable/session path | High | User-approved reference; never log full path or copy credentials |
| Item IDs, URLs, titles, usernames | High | Treat as private; no diagnostics or analytics |
| Search terms and index | High | Unlocked session only; do not persist by default |
| Database key | Critical | Device-only Keychain, not synchronizable |
| Proton cache-envelope key | Critical | Separate device-only Keychain record, not synchronizable, access control bound to retrieval because it is the only gate on Proton content |
| Quick-unlock key/envelope | Critical | Keychain access control bound to retrieval; the wrapped copy it protects is the sole approved at-rest key material |
| Build/signing credentials | Critical | Separate release environment and least privilege |
| Synthetic fixture secrets | High | Canary values; never production data; scan outputs |

## 3. Trust Boundaries

```text
User input and macOS UI
        |
        v
VaultSquire main process
  UI -> session actor -> provider registry
                 |              |
                 |              +-> VaultwardenProvider -> URLSession -> server
                 |              |
                 |              +-> ProtonCLIProvider -> Process -> pass-cli
                 |                                            -> Proton service
                 v
        encrypted SQLite <-> Data Protection Keychain
                 |
                 v
        optional future app extension
```

Every arrow crossing a boundary needs typed validation, cancellation, size
limits, stable error handling, and a rule for secret ownership.

### Trusted Components

VaultSquire necessarily trusts:

- macOS kernel, Security framework, Keychain, cryptographic primitives, and code
  signing enforcement;
- the selected compiler and release toolchain;
- reviewed dependency source and binary artifacts;
- Vaultwarden cryptographic rules at the supported pinned revision;
- the user to recognize the configured server and authorize unlock/copy.

### Partially Trusted Components

- Vaultwarden is trusted to authorize accounts and provide current records, but
  every field and resource parameter is untrusted input.
- Reverse proxies and private certificate authorities participate in transport
  trust but must not see plaintext vault records.
- Update and release hosting can deny or replay downloads but must not be able
  to create a valid signed release.
- The selected Proton CLI owns Proton secrets and crypto but its stdout, stderr,
  version, path, and process behavior remain untrusted at the app boundary.

## 4. Threat Actors And Scenarios

| Actor | Representative attack | Primary controls | Residual risk |
|---|---|---|---|
| Network attacker | Intercept login or redirect bearer token | HTTPS, ATS, system trust, strict redirect/origin policy | Compromised trusted CA remains powerful |
| Malicious configured server | Huge KDF, malformed crypto, oversized JSON, rollback | Resource caps, parser limits, authentication, snapshot counters | Can omit records or deny service |
| Malicious configured server | Change prelogin KDF parameters so the master key and auth hash become cheap to attack offline | Reviewed floor enforced before derivation, last accepted settings persisted per account, every later algorithm or parameter change requires explicit confirmation | A first login to a hostile server has no prior baseline to compare against |
| Stolen powered-off Mac | Read cache, tokens, backups | FileVault expectation, encrypted DB, device-only Keychain | Weak macOS account password affects protection |
| Same-user malware | Read clipboard, screen, process memory | App Sandbox where viable, Hardened Runtime, short clipboard lifetime, concealed UI, quick lock | Cannot be fully prevented while unlocked |
| Dependency attacker | Inject credential exfiltration | Minimal pinned dependencies, review, SBOM, provenance | Maintainer/build compromise remains possible |
| Replaced or malicious CLI | Exfiltrate item data or emit hostile output | User-approved absolute path, identity/version checks, bounded process contract, no shell | A trusted CLI update can still introduce defects or behavior drift |
| Malicious vault record | Parser crash, URI abuse, resource exhaustion | Bounded tolerant parser, safe URI confirmation, fuzzing | Legitimate extreme data may hit limits |
| Concurrent client | Overwrite newer record | Revision precondition, no blind retry, conflict UI | Some server objects remain last-write-wins |
| Local rollback attacker | Restore old cache and Keychain snapshot | Authenticated envelopes detect tampering; visible snapshot age | A valid older database can be replayed; no complete rollback defense in MVP |
| Shoulder/screen observer | Capture revealed secret | Mask by default, explicit reveal, clear on inactivity | Cameras and privileged capture remain |
| Support workflow | Leak vault in logs/bundle | Allowlist diagnostics, preview, canary scans | User can manually share a screenshot |

## 5. Core Security Invariants

### Vaultwarden Authentication

- Establish trusted HTTPS and validate effective origins before using account
  credentials.
- Normalize only the email input required by the provider protocol. Never trim,
  normalize, or case-fold a master password.
- Derive authentication material locally.
- Distinguish bad credentials, 2FA challenge, unsupported provider, rate limit,
  TLS, network, account lock, and incompatible crypto without exposing server
  internals or secrets.
- Never automatically retry a password or second-factor proof.
- Replace the locally stored refresh token atomically with the value returned by
  a successful refresh. Do not assume the server immediately invalidates the
  prior token or implements refresh-token reuse detection.
- Treat re-authentication as a complete login transaction. Atomically replace
  stored KDF parameters, wrapped user key, wrapped private key, and security
  stamp from the response; delete quick-unlock material when the security stamp
  changed; and complete a full sync before publishing decrypted views, so
  retained ciphertext is never decrypted under a rotated user key.
- If sync observes changed bootstrap data before re-authentication, do not
  promote that candidate. Reject new secret operations and invalidate any live
  session generation before any database or Keychain suspension, then persist
  `reauthenticationRequired`, retain the prior snapshot and bootstrap data,
  invalidate quick unlock, and remain locked. Clear the marker only when full
  re-authentication has validated and atomically committed a replacement
  hierarchy and snapshot.
- Treat refresh `invalid_grant`, security-stamp invalidation, or provider logout
  as a session transition, not a transient network error.
- Clear all partial keys and account state after any failed initial login.

### Cryptography

- Do not implement primitive algorithms from scratch.
- Keep the provider format separate from primitive wrappers.
- Validate KDF algorithm, integer range, multiplication overflow, CPU/memory
  ceiling, and cancellation before allocation.
- Enforce a reviewed lower bound as well as an upper bound. Bounds protect two
  different things: the ceiling protects the client from resource exhaustion, and
  the floor protects the user's master password from a server that returns cheap
  parameters.
- Persist the last accepted KDF algorithm and parameters per account. Require
  explicit user confirmation before deriving after any later algorithm or
  parameter difference, and record it as a non-secret diagnostic category.
  VaultSquire does not rank cross-algorithm or mixed-parameter changes;
  unchanged settings proceed without a prompt, and below-floor settings fail.
- Authenticate encrypted content before returning plaintext.
- Compare authentication tags in constant time.
- Return one generic integrity failure for MAC, padding, tag, or malformed
  ciphertext failures where detailed distinctions could form an oracle.
- Reject unknown encryption types without trying a "close" algorithm.
- Preserve unknown Vaultwarden ciphertext in its native records.
- Use OS CSPRNG output for keys, IVs, nonces, and device IDs.
- Never reuse a nonce or IV where the chosen provider algorithm forbids it.
- Include algorithm/version labels in local cache envelopes and Keychain records.
- Require byte-level interoperability vectors, malformed vectors, and reverse
  round trips before enabling a write format.

### Persistence

- Persist canonical Vaultwarden ciphertext, not decrypted Vaultwarden domain
  models. Persist Proton CLI output only after validation and immediate
  VaultSquire AEAD wrapping; label that snapshot as lossy and never call it
  provider-native ciphertext.
- Protect database pages, WAL, shared memory, journals, and temporary storage
  with the selected database-at-rest mechanism.
- Keep database and Proton cache-envelope keys in non-synchronizing, device-only
  Keychain records.
- Place the vault in the final App Group container from the first release;
  changing it when AutoFill arrives creates migration risk.
- Commit a complete snapshot and its generation/cursor in one transaction.
- Never copy a live SQLite database as a backup.
- Treat integrity diagnostics as local and secret-bearing.
- Encrypt backup/export artifacts or make plaintext export a separate explicit
  user operation with cleanup and prominent warnings.
- Retain the prior complete snapshot until the new snapshot authenticates,
  parses, validates, and commits.
- Bind a Proton cache envelope to its provider account, CLI version, capture
  generation, and schema version as authenticated metadata. Never use cached or
  freshly fetched lossy CLI item fields to construct a remote write. Write
  content comes only from current explicit user input; CLI output may contribute
  only specifically reviewed opaque identifiers or concurrency tokens.
- Logout must delete credentials, quick-unlock material, account store, temporary
  artifacts, state restoration, and app-owned clipboard values.

### Keychain And Quick Unlock

- Use the Data Protection Keychain explicitly.
- Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Set `kSecAttrSynchronizable` to false.
- Bind user presence or current biometrics to the Keychain read with
  `SecAccessControl`, not a separate prompt followed by unrestricted retrieval.
- Pass a dedicated `LAContext` into the Keychain operation and invalidate it on
  lock.
- Preserve Vaultwarden master-password unlock as recovery after biometric
  enrollment change or Keychain loss. If a Proton cache key is lost, discard the
  unreadable local snapshot and refetch through the authenticated CLI.
- If the Vaultwarden database key is unavailable (Keychain reset, restored
  backup without Keychain, or new device), discard the unreadable local
  database, generate a fresh key, and rebuild from an authenticated sync. Never
  derive the database key from the master password to work around its loss.
- Store the minimum wrapping material needed for quick unlock, not the master
  password. The approved construction is a random quick-unlock key in an
  access-controlled Keychain item plus an AEAD-wrapped copy of the Vaultwarden
  user key under that key in the encrypted database, as specified in
  `ARCHITECTURE.md`. This wrapped copy is the only exception to the rule that
  live provider keys never persist; a plaintext key at rest remains forbidden.
  The Proton cache-envelope key needs no such copy, because its own
  access-controlled Keychain record is already the gate.
- Delete both quick-unlock records on logout, on disabling the feature, and
  whenever the Vaultwarden security stamp changes, so the previous hierarchy is
  no longer available through quick unlock. The persisted
  `reauthenticationRequired` marker separately blocks master-password unlock
  after VaultSquire has observed the rotation.
- Bind the Proton cache-envelope key's release to user presence as well. Without
  it, Proton lock releases the whole snapshot on an unauthenticated Keychain
  read, which is not a security state transition.
- State the provider asymmetry plainly in user-facing text: Vaultwarden unlock is
  bound to the master password, Proton unlock is bound to a device-local factor.
- Never silently downgrade a Touch ID-only policy to login-password presence.
  Hardware without usable biometrics uses the declared `.userPresence` fallback,
  disclosed in the UI rather than substituted silently.
- Test screen lock, fast user switching, changed enrollment, removed hardware,
  Keychain reset, and restored backup.

### Memory And Lifecycle

- Confine keys and decrypted state to the `VaultSession` actor or provider-owned
  crypto state.
- Avoid `String` for key bytes and passwords except where required by system UI.
- Use mutable scoped buffers and overwrite owned storage when practical.
- Treat zeroization as best effort because Swift, Foundation, bridging, ARC, and
  copy-on-write can leave copies.
- Disable state restoration for secret-bearing windows and fields.
- Cancel KDF, decrypt, search, copy, reveal, and any plaintext-dependent sync
  work on app lock. Vaultwarden may continue ciphertext-only sync while the
  macOS user session is active. Proton refresh cannot: terminate every Proton
  CLI process because its output is plaintext.
- Increment a session generation before cleanup; all late results must fail the
  generation check.
- Close handles that expose decrypted projections and release provider unlock
  state on app lock. The Vaultwarden ciphertext-only sync path may reopen the
  encrypted store without provider decryption keys.
- Lock on configured inactivity, screen lock, screensaver/session resignation,
  system sleep, and explicit command. Screen lock and sleep cancel all sync and
  close every database handle.
- Do not claim that `NSWindow.sharingType`, `privacySensitive`, or obscuring UI
  reliably blocks native macOS screenshots.
- Never publish vault content to system integration surfaces: no CoreSpotlight
  indexing, `NSUserActivity`/Handoff payloads, Quick Look thumbnails, share
  sheets, Siri suggestions, or Services-menu providers containing item data.
- Use platform secure text entry for every master-password and secret input so
  secure event input is active; secure fields do not support copy, cut, or
  drag of the concealed value.
- Verify in release checks that core dumps are disabled for the app process. In
  controlled canary crashes, scan every app-owned artifact and every system
  crash report available to the test harness. This check covers fields and
  artifacts VaultSquire can control; it does not contradict the documented
  residual that macOS may page memory or retain unavailable system diagnostics.

### Search

- Index title, username, host, folder, and collection.
- Exclude passwords, TOTP seeds, recovery codes, card numbers, private keys, and
  hidden custom fields by default.
- Defer notes until the privacy/value tradeoff is explicitly accepted.
- Keep plaintext search indexes in memory. Persisting a logical plaintext index,
  even inside the encrypted database, is not preapproved and requires a new
  architecture and security decision.
- Normalize index and query text consistently and test composed/decomposed
  Unicode, emoji, punctuation, quotes, exclusions, and adversarial length.
- Bind every SQL argument and use a safe FTS query builder.
- Fetch secret fields only after item selection.
- Clear search queries and result projections on lock.

### Clipboard

- Copy secrets only after explicit user action.
- Default password expiry to 30 seconds and allow a shorter preference.
- Record the pasteboard `changeCount` when writing a secret and clear only while
  it still matches, so a later user copy is never erased. Do not retain the
  copied value or read the pasteboard back to prove ownership; the change count
  is sufficient and both alternatives extend the plaintext's lifetime.
- Attempt the same conditional clear on lock and termination.
- Use local-only/concealed hints where supported, but document that clipboard
  managers may ignore them.
- Never place TOTP seeds, private keys, or attachment keys on the clipboard.
- Explain that clearing cannot revoke data another process already read.

### Network And Self-Hosted Servers

- Require HTTPS outside explicit development-only loopback configuration.
- Use system trust, including administrator-installed private CAs.
- Provide no "continue anyway" certificate control.
- Do not pin certificates by default; private deployments rotate certificates
  and use private CAs.
- Preserve configured ports and path prefixes.
- Reject URL user info, fragments, and query strings in the server base URL.
- Use an ephemeral session with no URL cache, cookie store, or credential store.
- Use system proxy behavior and test authenticated proxies separately.
- Accept only same-origin, HTTPS-preserving redirects within the configured base
  path. A discovered cross-origin service must be approved before use and is a
  new endpoint, not a redirect exception.
- Never forward authorization, password-derived proof, cookies, or custom proxy
  headers to an unapproved origin. Approve a notifications origin before the
  first token-bearing connection and an upload origin before its first upload.
- Bound response bytes, decompressed bytes, item counts, nesting depth, string
  length, base64 output, attachment size, and concurrent operations.
- Do not fetch site icons from the configured server's icon service by default;
  each request discloses a plaintext item domain to the server operator and its
  network path. Icon display is deferred, or explicitly opt-in per account with
  the disclosure stated.
- Retry only idempotent reads and a single authenticated request after one token
  refresh. Reconcile ambiguous writes before any retry.
- Redact WebSocket query tokens and presigned attachment URLs.
- Treat notifications as hints and perform catch-up after reconnect.

### Proton CLI Process Boundary

- Require the official CLI to be installed separately by the user. Do not
  bundle, vendor, link, or copy it or any Proton implementation code.
- Resolve a user-approved absolute executable path. Never search an untrusted
  current directory, invoke a shell, or interpolate a command string. Resolve
  symlinks before approval and record signature and notarization status,
  including an explicit ad-hoc or unsigned marker; version output never
  authenticates the executable.
- Record and enforce an explicit allowlist of exact tested CLI versions/build
  identities and command-specific schemas. Every unlisted patch release fails
  closed.
- Let the CLI or browser collect Proton credentials and second factors.
  VaultSquire must never request, proxy, or store the Proton account password.
- Put no password, TOTP seed, note, title, username, URL, item content, token,
  search term, or credential material in argv or environment variables. Limit
  variable argv to reviewed opaque identifiers and non-secret selectors required
  by a tested read command.
- Send complete private write input only through stdin or another reviewed
  protected machine channel. Materialize no private CLI request or response in
  any plaintext file, regardless of lifetime or location.
- Bound stdin, stdout, stderr, execution time, decoded nesting, field sizes, and
  record counts. Parse stdout as untrusted data and treat stderr as
  secret-bearing even on failure.
- Keep raw stdout and stderr only in bounded transient buffers. Never persist,
  log, attach to errors, crash reports, or support bundles, or pass them to an
  analytics/crash SDK.
- Serialize commands per Proton account and terminate them on cancellation,
  lock, logout, sleep, screen lock, account removal, or session-generation
  change. Late output cannot publish state.
- Refresh and atomically replace the complete app-encrypted snapshot after every
  successful or ambiguous write. Never edit the lossy cache as if it were
  authoritative, and never blindly retry an ambiguous mutation.
- Disable any command that requires cached or freshly fetched lossy item fields
  to reconstruct existing content. Only current explicit user input plus
  specifically reviewed opaque identifiers/concurrency tokens may form a write.
- Prefer App Sandbox only if executable selection, child inheritance, and CLI
  session/keyring access pass on clean systems. Otherwise use the reviewed
  Developer ID Hardened Runtime build with minimal access, no privileged helper,
  and no Mac App Store target.

### Permissions And Provider Capabilities

- Calculate capabilities from provider response, role, item, policy, account
  state, connectivity, and supported implementation.
- Enforce capabilities inside use cases and provider mutation services.
- Negative-test menus, keyboard commands, context menus, deep links, AutoFill,
  copy, reveal, export, and accessibility actions.
- Respect Vaultwarden `viewPassword`, `edit`, delete/restore permissions, and
  collection restrictions even when ciphertext is locally decryptable.
- Calculate Proton actions from the exact detected CLI version and tested
  command contract. Disable each write whose complete private input cannot use
  an approved non-argv channel.
- Never translate an unsupported provider operation into a superficially
  similar operation such as archive versus trash or favorite versus pin. This is
  live, not hypothetical: Vaultwarden has per-user archiving while the researched
  Proton CLI exposes no archive command and documents its item deletion as
  permanent, so the archive action is simply absent for Proton accounts and
  Proton deletion is never described with reversible-trash wording.

### URI Opening

- Permit only parsed `https` and `http` destinations in the initial release.
- Display the effective host and scheme before leaving the app.
- Reject URL credentials and block `file`, `javascript`, `data`, privileged
  system schemes, and arbitrary custom schemes.
- Add a custom scheme only through an explicit user allowlist and scheme-specific
  security test.
- Never execute a URI through a shell.

## 6. Dependency And Supply-Chain Controls

- Prefer Apple platform APIs and the smallest dependency set.
- Record source repository, exact version/commit, checksum, license, transitive
  dependencies, binary origin, and owner for each dependency.
- Pin Swift packages and CI actions to immutable versions or commits.
- Do not consume unlicensed schemas, generated files, or binary frameworks.
- Do not consult or use Keyguard source, generated artifacts, schemas, tests,
  strings, assets, or detailed source-derived designs. Suspected contamination
  is removed and independently reimplemented.
- Treat the user-installed Proton CLI as an external trust boundary, not a build
  dependency. Record the selected path, observed version, and identity-check
  result without copying the executable or its credentials into the app.
- Verify downloaded source and binary checksums in CI.
- Generate SPDX or CycloneDX SBOMs for every release.
- Scan source, lock files, binaries, archives, entitlements, and notarization
  output.
- Build release artifacts on isolated, ephemeral workers.
- Keep Developer ID and notarization credentials separate from ordinary CI.
- Require two reviewers for authentication, cryptography, key storage, trust,
  persistence, updates, and release pipeline changes.
- Publish signed provenance following SLSA v1.2 where practical.
- Publish artifact checksums independently from the binary download.
- Inspect the final app recursively for unexpected dynamic libraries, writable
  executable paths, debug entitlements, JIT, unsigned memory, Apple Events,
  Accessibility, or network-server capability. The release target must not
  contain `com.apple.security.cs.get-task-allow`,
  `com.apple.security.cs.allow-dyld-environment-variables`,
  `com.apple.security.cs.disable-library-validation`,
  `com.apple.security.cs.disable-executable-page-protection`,
  `com.apple.security.cs.allow-unsigned-executable-memory`,
  `com.apple.security.cs.allow-jit`, or automation or Apple Events
  entitlements; every retained entitlement has a recorded justification.
- Treat every `temporary-exception` entitlement as prohibited by default. The
  sandboxed Proton CLI route is the only place one may even be considered, and
  only if the App Sandbox spike proves that user-selected executable access and
  child inheritance cannot be obtained through security-scoped bookmarks, which
  are not exceptions and are the required first choice. Adopting one needs an
  ADR naming the narrowest scope that works; if that ADR cannot be written, the
  answer is the direct Developer ID build, not a broader exception.
- The update mechanism, when introduced, must serve EdDSA-signed update
  metadata over HTTPS, verify the signature and bundle identity before
  installation, reject downgrades and unsigned or mismatched archives, and
  never install without a documented user-consent model.
- Commission an external review before 1.0 and after material crypto/storage
  architecture changes.

## 7. Diagnostics And Privacy

### Allowed Diagnostic Fields

- application version and build;
- macOS version and processor architecture;
- schema, SQLite, SQLCipher, and provider compatibility versions;
- operation stage and stable error category;
- durations, bounded counts, retry number, and response size;
- booleans such as offline, path-prefix configured, or private CA observed;
- random operation correlation ID with no stable account/item relationship.

### Forbidden Diagnostic Fields

- master passwords, OTPs, recovery codes, keys, hashes, tokens, cookies;
- email, username, title, note, password, card data, URI, TOTP seed;
- search query, clipboard value, generated password, private key;
- raw provider request/response or ciphertext;
- raw Proton CLI stdout/stderr, complete command input, session directory, or
  full executable path;
- full server URL, headers, certificate body, presigned URL, WebSocket URL;
- account, organization, collection, folder, item, attachment, or Send ID;
- filesystem paths derived from item or attachment names.

Use an allowlist at every logging call rather than logging arbitrary objects and
hoping privacy annotations redact them. Signposts carry counts and durations
only. Diagnostics remain local by default. A support bundle is generated only
on explicit request, displays a preview, applies deterministic redaction, and
contains no database or Keychain dump.

No analytics or third-party crash SDK ships in the initial release. Any future
upload requires opt-in consent, a data inventory, retention/deletion policy,
processor review, threat-model update, and canary leakage test.

## 8. Test Data And Environments

### Data Rules

- Never use a production vault in development, CI, screenshots, or support.
- Generate disposable accounts and records with unique canary strings.
- Mark every fixture as synthetic and record how it was generated.
- Encrypt or avoid secrets in repository fixtures; expected crypto bytes are
  acceptable only when generated for tests and reviewed.
- Scan test output, DerivedData, logs, results bundles, crash reports, temporary
  directories, database files, and release archives for canaries.
- Rotate disposable account credentials after shared or remote testing.

### Vaultwarden Matrix

| Lane | Purpose | Merge/release behavior |
|---|---|---|
| Pinned Vaultwarden 1.37.1 digest | Required current contract | Blocking |
| Previous validated release | Compatibility sentinel | Blocking only if declared supported |
| Older release | Defensive behavior | Must not crash/corrupt; explicit unsupported is acceptable |
| `main/testing` | Drift signal | Scheduled and initially nonblocking |
| Reverse proxy with path prefix | URL and redirect behavior | Blocking |
| Private CA deployment | System trust behavior | Blocking |

For every run, record package version, compatibility version, image digest,
database backend/migration, proxy topology, KDF, 2FA provider, organization
state, and fixture generator revision.

### Proton CLI Matrix

| Lane | Purpose | Merge/release behavior |
|---|---|---|
| Fake executable fixtures | Process, cancellation, bounds, malformed output, and leakage | Blocking |
| Official CLI 2.2.3 candidate | Establish initial command contract | Blocking once declared supported |
| Official CLI 2.2.4 | Current-release drift candidate | Unsupported until exact command/schema tests pass |
| Previous tested CLI release | Compatibility sentinel | Blocking only if declared supported |
| Unsupported newer/older version | Fail-closed capability behavior | Blocking |
| App Sandbox spike | Executable, inheritance, session, and keyring feasibility | Architecture decision gate |
| Direct Hardened Runtime build | Reviewed fallback and clean-Mac behavior | Blocking if selected |

For every live CLI run, record the executable identity result, exact CLI
version, macOS version, processor architecture, distribution mode, command
capability manifest revision, and synthetic fixture revision. Never record the
full executable/session path or account content in test artifacts.

## 9. Verification Layers

### Unit Tests

Required unit targets:

- URL parse/normalize/resolve and origin policy;
- DTO decoding with absent, null, empty, unknown enum, and unknown fields;
- typed error precedence and redaction;
- account and session state transitions;
- cancellation and session-generation checks;
- provider capabilities and every negative action path;
- storage migrations and provider-envelope fidelity metadata;
- process argument/environment construction, bounds, timeout, termination, and
  secret-safe error mapping;
- Proton CLI version/schema manifests and app cache-envelope encode/decode;
- search normalization, parsing, ranking, and safe FTS query construction;
- pasteboard ownership/expiry;
- log allowlist and support-bundle redaction.

### Cryptographic Tests

- PBKDF2 at minimum, default, warning, and maximum bounds.
- Argon2id at minimum, default, and maximum CPU/memory/parallelism bounds.
- Unicode and whitespace-sensitive email/password cases.
- Exact master auth hash, HKDF labels, user key, organization key, and item key
  bytes.
- Every supported encrypted-string type and explicitly unsupported type.
- Bit flips in type, IV/nonce, ciphertext, tag/MAC, wrapped key, and padding.
- Truncated, oversized, malformed base64, duplicate segment, and integer-overflow
  inputs.
- Reference-created data consumed by VaultSquire.
- VaultSquire-created synthetic data consumed by the tested reference client
  before writes can ship.
- Proton cache-envelope known-answer, wrong-key, metadata-substitution, nonce,
  truncation, and corruption cases. These test VaultSquire storage encryption,
  not Proton cryptography.
- Constant-time comparison implementation review.
- Attachment sizes around zero, one byte, cipher block, stream chunk, and limit.
- TOTP known-answer vectors, clock skew, digit count, period, and algorithm.
- KDF baseline changes: an unchanged response proceeds without confirmation;
  every algorithm or parameter difference from the last accepted settings
  requires confirmation before derivation; and a response below the reviewed
  floor is refused outright. Include cross-algorithm and mixed-direction Argon2
  changes to prove no implicit strength ranking occurs.

Deterministic crypto fixtures, meaning known-answer, malformed-input, and
round-trip vectors, require a 100 percent pass rate with no flaky retry.

Constant-time behavior is verified differently. A statistical timing measurement
on shared CI hardware is inherently noisy, so a no-retry release gate on it would
either flake or be loosened until it proves nothing. Require instead a reviewed
constant-time primitive, code review of every comparison site, and a scheduled
dudect-style run on dedicated hardware whose regressions open tracked defects
rather than blocking merges.

### Vaultwarden Protocol Contract Tests

- Configuration discovery and protocol/app version separation.
- Base URL variants: trailing slash, explicit port, path prefix, IPv4, IPv6,
  IDN/punycode, and private DNS name.
- TLS failures: hostname, validity, unknown CA, incomplete chain, downgrade.
- Redirects: same origin, cross origin, path-prefix escape, HTTPS to HTTP.
- Prelogin and password login for PBKDF2 and Argon2id.
- Every advertised supported and unsupported 2FA provider.
- Refresh replacement, expiry, invalid grant, security-stamp logout, and rate limit.
- Full sync, no-change revision check, locked sync, cancellation, and reconnect.
- Personal and organization keys, roles, collections, and hide-password policy.
- Every supported item type, hidden/custom field, reprompt, folder, favorite,
  trash, archived state, and unsupported item.
- Master-password reprompt accepts only a newly entered correct master password;
  quick unlock and an already-unlocked session are negative test cases.
- Archive and unarchive through the dedicated routes: per-user visibility so a
  second organization member's view is unchanged, archived items excluded from
  default lists and search, archived state distinct from trash, and item content
  unmodified by the operation.
- Unknown fields survive read and later write fixture paths.
- Error casing and compact/default/identity/validation response variants.
- Malformed, duplicate, reordered, deeply nested, oversized, and truncated JSON.

### Proton CLI Contract Tests

- Missing executable, changed executable identity, unsupported version, missing
  command, unauthenticated/expired session, and user-cancelled login.
- Vault/share listing, item listing/view, duplicate names, compound identity,
  every supported item mapping, and explicit unsupported-field presentation.
- Exact argv and environment allowlists proving no synthetic secret or item
  content crosses either channel.
- Bounded stdin/stdout/stderr, malformed/non-JSON/duplicate/unknown fields,
  nonzero exit, signal termination, timeout, cancellation, and output after
  lock/session-generation change.
- Full refresh candidate validation, immediate AEAD wrapping, atomic publication,
  stale-state display, and prior-snapshot retention on every failure.
- Per-command write fixtures proving complete private input uses an approved
  channel, followed by official-client cross-read and full CLI refresh.
- Negative write fixtures proving cached and freshly fetched lossy item fields
  cannot enter command content; only reviewed opaque identifiers/concurrency
  tokens are accepted from CLI output.
- Success response lost after commit, interruption before/during/after stdin,
  and ambiguity reconciliation without blind retry.
- Unsupported CLI versions automatically remove affected capabilities while
  retaining safe cached reads.
- App Sandbox and direct-build runs on clean Macs, including selected executable,
  session directory, keyring, sleep, screen lock, and logout behavior.

### Persistence And Fault-Injection Tests

- New install, every migration path, interrupted migration, and newer-schema
  extension behavior.
- Kill process before, during, and after candidate snapshot transaction.
- Corrupt header, page, WAL, row envelope, generation, and associated metadata.
- Corrupt, truncate, swap between accounts, or replay a Proton cache envelope;
  raw CLI plaintext must never become the recovery fallback.
- Truncate, duplicate, swap between accounts, replay old file, and restore
  backup.
- Disk full, permission failure, read-only filesystem, and database busy.
- Lock/logout during KDF, database open, sync, commit, projection, and search.
- Keychain missing, duplicate, inaccessible, changed ACL, changed biometrics,
  locked device, and restored backup.
- Quick-unlock lifecycle: enrollment change destroys the quick-unlock key and
  every copy wrapped under it, master-password unlock still recovers the
  Vaultwarden account, an inaccessible Proton cache key discards the snapshot and
  refetches through the CLI, and a security-stamp change deletes the wrapped
  copy while the durable re-authentication marker blocks the old master password
  from offline unlock.
- Rotation publication: detect changed bootstrap data during both locked and
  unlocked sync, then inject failure, cancellation, and process death before and
  during marker persistence and re-authentication. New operations are rejected
  and any live session generation changes before the first suspended cleanup
  step.
  After marker commit, the prior snapshot/generation remain current, the marker
  blocks old-password and quick unlock, and only a fully validated replacement
  transaction clears it. Marker-write failure leaves the running process locked.
- Scan every local artifact for fixture canaries after lock and logout.

### Mutation And Conflict Tests

Before Vaultwarden write support:

- official client creates, VaultSquire reads and updates, official client reads;
- VaultSquire creates, official client reads and updates, VaultSquire reads;
- two clients update distinct and same fields with deterministic revision gaps;
- connection drops before send, during body, after server commit, and before
  response parsing;
- refresh occurs during a mutation;
- role/policy changes between edit and submit;
- item is trashed, archived, deleted, moved, or unshared while edit UI is open;
- two clients race an archive and an unarchive of the same item: the outcome is
  one of the two states, item content is unchanged, and the losing client
  converges on the next authoritative read;
- an archive request is never issued as a full-object update carrying
  `archivedDate`;
- unsupported native fields survive a supported field update;
- retry never occurs until an authoritative read proves the prior result;
- folder and object types without a stale-write guard visibly disclose their
  last-write-wins limitation and have an approved endpoint-specific risk ADR, or
  remain outside the release manifest.

For every Proton CLI mutation enabled by the capability manifest:

- exact stdin/protected-input bytes are tested without exposing them in failure
  output;
- the official CLI and an official Proton client cross-read the result;
- cancellation and interruption at each process stage are reconciled by a full
  refresh;
- an untested version, argv-only command, incomplete input surface, or plaintext
  file requirement leaves the capability disabled.

### Fuzzing

Fuzz targets:

- URL and environment parser;
- JSON DTOs and date/ID/enum decoders;
- base64 and encrypted-string parser;
- KDF parameter decoder and arithmetic;
- Vaultwarden encrypted-record and local cache-envelope decoder;
- Proton CLI JSON and cache-envelope decoder;
- process error/status decoder and capability-manifest parser;
- cache/database migration input;
- search query parser and FTS pattern builder;
- notification MessagePack framing;
- attachment framing and metadata;
- import/export formats when introduced.

Short bounded fuzz smoke tests run on pull requests. Extended fuzzing runs on a
schedule. Every crash, hang, assertion, excessive allocation, unexpected
plaintext diagnostic, and non-cancellation is a tracked defect; security parser
findings block release until triaged.

### macOS UI And Accessibility Tests

- Complete account form with keyboard only.
- Error focus and 2FA method selection.
- Secure-field reveal behavior and VoiceOver announcement.
- Main list/detail navigation and all copy commands.
- Quick Search on multiple Spaces and over full-screen applications.
- VoiceOver, Voice Control, Full Keyboard Access, increased contrast, reduced
  motion, Dynamic Type/text sizing, and non-color status cues.
- Screen lock, sleep, fast user switching, and inactivity transition.
- Clipboard is not overwritten after another application copies a value.
- No secret is spoken, exposed as an accessibility label, placed in drag data,
  shown in recent documents, or restored after relaunch without explicit action.
- Built-target and runtime checks find no item content in CoreSpotlight,
  `NSUserActivity`/Handoff, Quick Look, share sheets, Siri suggestions, or a
  Services provider.
- Master-password and secret fields use secure text entry and reject copy, cut,
  and drag of concealed values.
- Controlled crash runs verify core dumps are disabled and scan every available
  app-owned and system crash artifact for fixture canaries.

Accessibility APIs must not be disabled as an attempted security boundary.

### Performance And Resource Tests

Test release builds with generated 1,000, 10,000, and 100,000-item vaults on:

- representative Apple Silicon;
- oldest supported Intel hardware if Intel is shipped;
- every supported macOS major version for smoke coverage.

Measure:

- cold and warm launch;
- search panel display;
- KDF separately by provider parameters;
- database open and integrity check;
- first list projection and complete index build;
- each search keystroke and result render;
- full/no-change sync processing;
- Proton full CLI refresh, process startup, JSON decode, AEAD wrapping, and
  post-write refresh;
- lock cleanup;
- memory high-water mark, allocation growth, CPU, disk writes, and energy;
- main-thread stalls and actor contention.

Use XCTest metrics, Instruments, unified signposts, Time Profiler, Allocations,
Leaks, Network, Points of Interest, and Energy. A performance regression cannot
be waived by changing the budget without a documented product decision.

## 10. CI And Review Gates

### Every Change

- Build all touched targets in release-compatible mode.
- Run formatting/linting without rewriting unrelated files.
- Run unit and relevant known-answer tests.
- Run secret and license scans.
- Review generated lockfile/dependency changes.
- Require focused review for security-boundary changes.

### Every Pull Request Affecting Security Boundaries

- Add or update positive, negative, cancellation, and leakage tests.
- Link the controlling threat and invariant.
- Record changed provider/source revision if behavior changed.
- Inspect logs and diagnostics generated by the new path.
- Run sanitizers and strict concurrency diagnostics where applicable.
- Require two reviewers for auth, crypto, trust, persistence, Keychain,
  extensions, updater, signing, or release code.

### Nightly/Scheduled

- Full Vaultwarden contract matrix.
- Fake and supported-version Proton CLI contract matrix for every manifest
  capability.
- Extended fuzzing.
- Large-vault performance sentinel.
- Dependency vulnerability and license scan.
- Current Vaultwarden release/main drift check.
- Clean install and migration fixtures.

### Release Candidate

- Freeze a machine-readable or reviewed feature manifest. Only tests for
  features in that manifest are release-blocking; deferred-feature tests remain
  nonblocking signals. P0/P1 labels in the protocol matrix are test priorities,
  not product phases.
- All tests from a clean checkout and immutable dependency resolution.
- Release build on isolated worker.
- Full server, crypto, storage, UI, accessibility, performance, and leakage
  matrix.
- Proton CLI capability manifest, selected version window, sandbox/direct-build
  decision, and clean-Mac process tests when Proton support is included.
- Recursive entitlement and binary inspection.
- SBOM, provenance, checksums, signature, notarization, and stapling.
- Install and launch verification on clean Macs.
- Upgrade from every supported prior VaultSquire release.
- Rollback and emergency update rehearsal.
- Documentation and supported-version matrix review.

## 11. Stop-Ship Gates

A release is blocked if any applicable item is false. "Applicable" means the
feature is in the release manifest; global auth, storage, lifecycle, supply-chain,
and leakage controls always apply.

- Licensing review approves every source, dependency, fixture, schema, and
  redistributed artifact.
- The Keyguard history-isolation and provenance gate has passed before any
  application code is accepted.
- All pinned Vaultwarden workflows applicable to the release manifest pass.
- Every Proton read workflow in the manifest passes against the fake boundary
  and each declared supported official CLI version.
- Every enabled Proton write has a secret-safe complete-input contract,
  official-client round trip, ambiguity test, and automatic unsupported-version
  disable path. No cached or freshly fetched lossy CLI item field is used as
  write content; only reviewed opaque identifiers/concurrency tokens may come
  from CLI output.
- Every cryptographic vector passes without retries.
- Unknown encryption never downgrades or falls back.
- No open critical or high security defect exists.
- Every medium security defect has an owner, mitigation, and explicit release
  decision.
- No known silent data loss or ambiguous blind retry exists.
- Secret canary scans find no plaintext in prohibited artifacts.
- Proton canaries are absent from argv, environment variables, logs, raw
  persisted stdout/stderr, temporary files, crash reports, and support bundles.
- Lock, logout, token replacement, and snapshot atomicity fault tests pass.
- TLS, redirect, private CA, proxy, path-prefix, and malicious-server tests pass.
- Permissions are negative-tested across UI and use-case entry points.
- Required accessibility flows pass.
- The controlling performance budgets in `PLAN.md` pass on named release
  hardware.
- Final entitlements are minimal and reviewed.
- SBOM, vulnerability scan, provenance, signature, notarization, checksum, and
  clean-machine install checks pass.
- External review has no unresolved exploitable finding for 1.0.
- Vulnerability intake, emergency release, signing compromise, and update
  revocation procedures exist and have owners.
- User documentation accurately states support boundaries and residual risks.

## 12. Vulnerability And Incident Process

Before external testing:

- publish a private security contact and response expectations;
- define supported versions and end-of-support policy;
- classify confidentiality, integrity, authentication, data-loss, and supply
  chain severity;
- preserve minimal release metadata without collecting vault data;
- maintain an emergency signing and release path;
- define how to revoke or replace a compromised update feed or signing identity;
- coordinate upstream disclosure when a finding belongs to Vaultwarden,
  Bitwarden, Proton/the official CLI, Apple, or a dependency;
- never ask a reporter to submit production vault content;
- provide a synthetic reproduction harness;
- document post-incident rotation guidance for tokens, master passwords, and
  organization keys according to the affected boundary, and for Proton CLI
  sessions/account credentials according to Proton's guidance.

## 13. Standards And Primary References

All links were accessed on 2026-07-31.

- [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple App Transport Security](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity)
- [Apple Configuring App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [Apple Data Protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
- [Apple Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
- [Apple Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
- [Apple Notarizing macOS Software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple Process](https://developer.apple.com/documentation/foundation/process)
- [Apple Sharing Keychain Items](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- [Apple Swift 6 Adoption](https://developer.apple.com/documentation/swift/adoptingswift6)
- [GRDB Database Sharing](https://github.com/groue/GRDB.swift/blob/v7.11.1/GRDB/Documentation.docc/DatabaseSharing.md)
- [NIST SP 800-218 Secure Software Development Framework](https://csrc.nist.gov/pubs/sp/800/218/final)
- [NIST SP 800-161 Rev. 1 Update 1](https://csrc.nist.gov/pubs/sp/800/161/r1/upd1/final)
- [OWASP Application Security Verification Standard](https://owasp.org/www-project-application-security-verification-standard/)
- [OWASP Mobile Application Security Verification Standard](https://mas.owasp.org/MASVS/)
- [Proton Pass CLI Developer Resources](https://protonpass.github.io/pass-cli/developer-resources/)
- [SLSA Specification v1.2](https://slsa.dev/spec/v1.2/)
- [SQLCipher API](https://www.zetetic.net/sqlcipher/sqlcipher-api/)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)
- [SQLite Write-Ahead Logging](https://www.sqlite.org/wal.html)
