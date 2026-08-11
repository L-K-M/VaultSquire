# Adversarial Security Review — 2026-08-11

- Status: review record and remediation tracker
- Scope: the full Swift codebase at the review base commit, against the
  invariants in `SECURITY_AND_TESTING.md`, `ARCHITECTURE.md`, and
  `IMPLEMENTATION_REPORT.md`
- Method: manual adversarial code review of every app source file, with the
  crypto, Keychain, session, network, CLI-boundary, persistence, and UI
  surfaces traced end to end. No production vault data was used or needed;
  every referenced fixture is synthetic.
- Reviewer: automated adversarial review, requested by and reported to the
  maintainer. This document is evidence, not a normative document; conflicts
  with the controlling documents resolve in their favor.

The review base is `main` at the time of writing (the application contains
Workstreams 1-3 merged slices plus Vaultwarden sync/read, write, multi-vault,
biometric-unlock, Proton, and 1Password work). Findings are grouped by
severity. "This PR" refers to the pull request that introduces this document.

## Fixed in this PR

### F1 — Full-object cipher PUT silently destroyed unmodeled server state (High)

`VaultwardenWriteService.updateLogin` built its `PUT /api/ciphers/{id}` body
from a small fixed field set. Vaultwarden replaces the whole cipher with the
request body, so every edit silently:

- wiped the item's **password history** (`PasswordHistory` omitted),
- cleared the item's **master-password reprompt** requirement (`Reprompt`
  omitted — a security regression on that item, not just data loss),
- dropped the item's **per-item cipher key** (`Key` omitted),
- dropped collection membership (`CollectionIds`) and carried no revision
  precondition, so a concurrent edit already known to the client could be
  overwritten blindly (no `lastKnownRevisionDate`).

This contradicts `ARCHITECTURE.md` ("For full-replacement writes, start from
the latest raw object, change only supported fields, and preserve opaque
values. Refuse the write if the endpoint cannot safely pass through unknown
data") and the stop-ship rule "no known silent data loss."

**Fix:** the write path now passes every preserved field through verbatim,
sends `lastKnownRevisionDate` as the concurrency precondition, and maps
409/412 to a distinct `VaultwardenWriteError.conflict` that tells the user to
sync rather than retry. Regression tests:
`VaultwardenWriteServiceTests.testUpdatePreservesHistoryRepromptKeyAndMembershipVerbatim`,
`.testRevisionConflictIsReportedDistinctly`.

### F2 — Per-item cipher keys unsupported: modern items unreadable, edits destructive (High)

Current official Bitwarden clients encrypt every new cipher's fields under a
random per-item key, wrapped in the cipher's `Key` field. The model had no
`Key` field and the decryptor read every field directly under the account
key, so any such item failed authentication and silently displayed as
"Unnamed item" with empty fields. Worse, editing it produced an all-empty
draft and the save re-encrypted those empty fields under the user key and
replaced the server object — permanent destruction of the item's content.

The `VaultwardenSyncModels` comment claiming "the raw sync bytes are retained
by the cache" was also false: the sealed cache stores the re-encoded decoded
model, so unknown wire fields were lost at persistence.

**Fix:** `VaultwardenCipherModel` decodes and round-trips `Key`,
`VaultwardenKeyUnwrap.unwrapCipherKey` unwraps the item key under the
account key for the cipher's scope, and every read, detail, draft, and write
resolves the cipher's actual key. A cipher whose wrapped item key fails is
shown undecrypted rather than garbage. Regression tests:
`VaultwardenCipherFidelityTests.testCipherKeyDecryptsFieldsUnderTheItemKey`,
`.testACipherKeyFromAnotherCipherDecryptsNothingRatherThanGarbage`,
`.testPreservationFieldsDecodeAndRoundTrip`.

### F3 — Editing an organization item re-encrypted it under the personal key (High)

`VaultwardenAccountService.update` always passed `keyring.userKey` to the
write service, even for organization-owned ciphers. Saving an edit to an
organization item re-encrypted its fields under the user's personal key,
corrupting the item for every other organization member.

**Fix:** the write key is the cipher's resolved key (item key, else the
organization key, else the user key). Organization items with no available
organization key fail closed as `encryptionFailed`.

### F4 — Server permissions not enforced (High)

Cipher `Edit`/`ViewPassword` flags (into which Vaultwarden folds collection
`readOnly`/`hidePasswords` policy) and `Permissions.Delete/Restore` were not
decoded. Every item offered reveal, copy, edit, and archive regardless of
server policy — violating "server permissions and item restrictions are
enforced by use cases, not only by disabled buttons" and "respect
`viewPassword`... even when ciphertext is locally decryptable."

**Fix:** the flags are modeled. `detail` emits no concealed field when
`viewPassword == false` (so reveal/copy have nothing to act on), and `draft`
and `update` refuse `edit == false`. Master-password **reprompt** is now
*preserved* on write, but interactive reprompt verification remains
unimplemented — see R2. Regression tests:
`VaultwardenCipherFidelityTests.testViewPasswordFalseEmitsNoConcealedFields`,
`.testDraftIsNilForEditForbiddenTrashedOrArchivedItems`.

### F5 — Trashed and archived items presented as live (High)

`DeletedDate`/`ArchivedDate` were not modeled, so `/api/sync`'s trashed and
archived ciphers appeared in the default list and search as normal items and
could be revealed, copied, and edited — contrary to "archived items excluded
from default lists and search, archived state distinct from trash."

**Fix:** both states are modeled; projections, details, drafts, and updates
exclude them. Regression tests:
`VaultwardenCipherFidelityTests.testTrashedAndArchivedCiphersProduceNoProjectionOrDetail`.

### F6 — Clipboard: no expiry, no ownership tracking, no clear on lock/terminate (High)

`VaultItemDetailView.copyToPasteboard` wrote secrets to the general
pasteboard and forgot them. The clipboard section of `SECURITY_AND_TESTING.md`
requires a 30-second default expiry, `changeCount` ownership (clear only
while the count matches, never read the value back), concealed/transient
hints, and the same conditional clear on lock and termination.

**Fix:** `ClipboardService` is the single copy path. Secrets expire (30 s
default), clears are change-count-gated, lock and termination clear an owned
secret, and concealment hints are set (documented as hints a clipboard
manager may ignore). Regression tests: `ClipboardServiceTests` (expiry,
ownership, later-user-copy protection, lock no-ops).

### F7 — No automatic lock (High)

Only the explicit lock command existed. `SECURITY_AND_TESTING.md` requires
lock on configured inactivity, screen lock, screensaver/session resignation,
system sleep, and explicit command. A sleeping or screen-locked Mac kept its
unlocked vault on screen for whoever next touched it.

**Fix:** `AutoLockController` locks on screen lock, screensaver start, system
sleep, and fast-user-switch session resignation, plus a configurable
inactivity timeout (default 15 minutes, `VaultSquire.autoLockMinutes`, 0
disables only the inactivity trigger). Lock also cancels every tracked
in-flight task for the vault, so Proton/1Password CLI processes are
terminated by the executor on lock rather than finishing into a closed vault.
Regression tests: `AutoLockControllerTests`.

### F8 — URI opening allowed arbitrary schemes with no confirmation (Medium)

The detail view rendered any website value as a SwiftUI `Link` as long as it
parsed with some scheme — `file:`, `javascript:`, and custom schemes included
— and opened it immediately. The URI-opening invariants permit only parsed
`https`/`http`, reject URL credentials, and require the effective host and
scheme to be shown before leaving the app.

**Fix:** `URIOpeningPolicy` admits only http/https with a host and no user
info; the detail view confirms with the effective `scheme://host[:port]`
before handing the URL to the system. Regression tests:
`URIOpeningPolicyTests`.

### F9 — Refresh-token rotation race between sync and writes (Medium)

`sync()` and `performWrite()` each constructed a fresh
`VaultwardenTokenRefresher` from the same stored refresh token, so the
one-in-flight coalescing never applied across operations. A sync overlapping
a write issued two refreshes with one token: the loser's rotated token was
lost, or — on a server that invalidates on rotation — a spurious
session-expired. The Keychain store's contract explicitly requires callers
to serialize concurrent writes for one account.

**Fix:** `SerialOperationGate` (a task chain — actors are re-entrant and do
not serialize suspending work) serializes both operations per account.
Regression tests: `SerialOperationGateTests`.

### F10 — KDF-change detection never ran (Medium)

The security plan requires the last accepted KDF parameters to be persisted
per account and any later change to require explicit confirmation before
derivation. `AddAccountModel.signIn` always passed `lastAcceptedKDF: nil`,
so the (fail-closed) change policy was never fed a baseline and a server
could silently weaken KDF parameters between logins.

**Fix:** the persisted snapshot's KDF is the baseline; a difference suspends
the login on a confirmation panel (`PromptingKDFChangePolicy`, mirroring the
origin-approval flow) before any derivation. Unchanged configurations never
prompt; below-floor configurations are still refused outright. Regression
tests: `AddAccountModelTests` KDF-change confirmation cases (unchanged,
approved, declined — including that a decline never reaches the token grant
and keeps the old baseline).

### F11 — Proton `item list` secrets could be sealed into the snapshot (Medium)

`ProtonReadModel.decodeItems` decoded `password`, `totp`, and `note` from the
list payload into `ProtonItem`, which `refresh()` then sealed into the
at-rest snapshot — contradicting the design comment that secrets "stay out of
the at-rest snapshot entirely" and the posture the 1Password decoder
implements explicitly. No supported CLI build is known to print secrets from
`item list`, but the payload is undocumented and the decoder must not trust
it.

**Fix:** list decoding retains only non-secret fields; secrets enter an item
only through an explicit `item view` read. Regression test:
`ProtonReadModelTests.testListPayloadSecretsAreNeverCapturedIntoSummaries`.

### F12 — Proton version gate admitted pre-releases named after a stable (Low)

`ProtonCLIVersionGate.parseVersion` matched only the dotted numeric token, so
`2.2.4-beta.1` was admitted as the tested stable `2.2.4`. The 1Password gate
deliberately captures the suffix for exactly this reason.

**Fix:** the suffix is captured into the compared token. Regression test:
`ProtonCLIVersionGateTests.testAPrereleaseSuffixNeverInheritsAStablesAdmission`.

### F13 — Legacy type-0 accounts told their password was wrong (Low)

`VaultwardenVaultUnlock` collapsed `legacyEncryptionDetected` into
`.wrongPassword`, sending users retrying a correct password forever.

**Fix:** a distinct `legacyEncryptionUnsupported` outcome with migration
guidance.

### F14 — Master-password zeroization was a no-op (Low)

`AppModel.unlock` built the password `Data` outside the task, then copied it
in. `Data` is copy-on-write: zeroizing the copy detached it and zeroed the
detached buffer, leaving the original bytes intact until the task was
released.

**Fix:** the `Data` is constructed inside the task so the zeroized buffer is
the only copy. (`VaultwardenKeyDerivation.authenticationHash` and the
biometric path were already effective.) Zeroization remains best-effort by
design; the keyring itself is not explicitly overwritten on lock — recorded
under R5.

### F15 — Resource bounds checked only after full buffering (Low)

- Site-icon fetch (an opt-in feature that contacts item-named hosts) bounded
  the body only after downloading it fully. Now enforced mid-transfer.
- The three sealed caches (`VaultwardenVaultCache`, `ProtonSnapshotCache`,
  `OnePasswordSnapshotCache`) read files unbounded before opening. Now
  size-checked (128 MB, above the 50 MB sync bound) before buffering.

### F16 — Unknown cipher item types were flattened (Low)

A cipher whose `Type` the build did not know (e.g. 5 SSH key, 6-8
response-only types) decoded as `.secureNote` and was re-persisted as type 2,
contrary to "unknown cipher and encryption types... are never silently
dropped, rewritten, or treated as an empty known type."

**Fix:** `ItemType` is now a raw-value-preserving type; unknown types display
as unsupported and round-trip exactly. Regression tests:
`VaultwardenCipherFidelityTests.testUnknownAndNewerItemTypesSurviveRoundTrips`.

## Documented, not fixed in this PR

### R1 — Sync adopts rotated key bootstrap data without the reauthentication gate (Medium)

`VaultwardenSyncService.merge` adopts a changed `wrappedUserKey`/
`wrappedPrivateKey` from the sync profile silently. The security plan
requires detecting changed bootstrap data, persisting
`reauthenticationRequired`, retaining the prior snapshot, invalidating quick
unlock, and gating new secret operations until a full re-authentication
commits a validated replacement. Today a key rotation surfaces only as a
misleading "wrong password" on the next unlock (biometric unlock self-heals
as invalidated with a correct message). The `EncryptedStore`
reauthentication-marker contract exists but has no production
implementation. This needs the re-authentication flow designed as its own
change (marker persistence, unlock gating, replacement transaction, negative
tests), not a patch.

### R2 — Master-password reprompt is preserved but not yet enforced (Medium)

Reprompt ciphers are now faithfully modeled and never stripped by an edit
(F1), but the interactive re-verification the architecture requires before
reveal/copy/edit is not implemented. Until it ships, reprompt items behave
like any other locally. This is a documented gap, now visible in one place
(`VaultwardenCipherModel.requiresReprompt`) for the follow-up change to
enforce against, with the negative tests the plan requires (quick unlock and
an already-unlocked session must not satisfy it).

### R3 — Proton/1Password cache-envelope keys are not user-presence bound (Medium)

The security plan binds the Proton cache-envelope key's release to user
presence ("without it, Proton lock releases the whole snapshot on an
unauthenticated Keychain read, which is not a security state transition").
`DeviceDataKeyStore` uses plain `WhenUnlockedThisDeviceOnly` items with no
`SecAccessControl`, for all three snapshot caches. Doing this properly means
caching the key for the unlocked session (per-read prompts are not viable),
which is a session-lifecycle design change that belongs with R1's session
work. The CLI snapshot caches contain no secrets after F11 (titles,
usernames, URLs, vault names only), and offline read is not wired to the UI.

### R4 — CLI executable identity is not verified (Medium, already gated)

The runners locate and version-gate the CLIs but do not verify code
signature/notarization of the resolved executable. `WORKSTREAM_1.md` already
records "executable code signature and notarization status recorded at
approval (not implemented; blocks Workstream 10)" as owed evidence, so this
restates rather than reports it: a replaced binary reporting an allowlisted
version string would pass today's gate.

### R5 — Lock performs no explicit zeroization of the keyring (Low)

Lock drops the keyring by ARC release only; the user key and organization key
buffers are not overwritten. Zeroization is documented as best-effort in the
security plan, and Swift/ARC copies make guarantees impossible, but the plan
also says "use mutable scoped buffers and overwrite owned storage when
practical." Making the keyring's buffers explicitly overwrite-on-drop is a
small, mechanical follow-up; F14 fixed the case where the documented intent
was actively broken.

### R6 — In-flight Vaultwarden HTTP calls are not cancelled on lock (Low)

Lock cancels every tracked task and drops results by generation, and Proton /
1Password CLI processes are terminated by the executor's cancellation
handler. Vaultwarden network calls inside the serialized operation gate run
to their (bounded) completion because the gate's task chain deliberately
does not propagate caller cancellation into an in-flight operation — a
canceled operation must still finish before the next queued one. This is
ciphertext-only traffic and consistent with "ciphertext-only sync may
continue while locked," recorded here so the choice is explicit.

### R7 — Proton refresh skips an unreadable vault and seals the partial result (Low)

`ProtonAccountService.refresh` skips a vault whose item list fails and seals
the remaining items as the authoritative snapshot, silently dropping that
vault's items from the offline cache (the same pattern exists in the
1Password refresh). "A failed or cancelled sync cannot replace the last
complete encrypted vault" argues for either failing the refresh or marking
the snapshot partial and surfacing that in the UI. Not changed here because
the honest presentation (partial-state display) needs a UI decision.

### R8 — Legacy encryption accounts need a server round trip to be noticed (Low)

Type-0 legacy detection (F13) fires only when unwrapping the stored user
key; a vault whose items are type 0 but whose key wrap is type 2 shows those
items as undecryptable ("Unnamed item") without the legacy explanation. A
per-item legacy indicator is a presentation-layer follow-up.

## Verification status of this PR

- New and updated unit tests accompany every fix, per the
  security-boundary-change rule (positive, negative, and leakage cases where
  applicable). This environment is Linux; the `macOS Product` lane
  (`scripts/ci.sh` — build, test, sign, inspect, three configurations) is the
  executing gate for compilation and test results, exactly as for every
  application change in this repository.
- No dependency was added; `DEPENDENCIES.md` is unchanged. All cryptography
  is CryptoKit/CommonCrypto/Security framework.
- No normative document (`PLAN.md`, `SECURITY_AND_TESTING.md`,
  `ARCHITECTURE.md`) was modified; this review is subordinate evidence.

## Scope notes and non-findings

Reviewed and found consistent with the invariants (no action):

- KDF floor/ceiling validation with checked arithmetic; PBKDF2/HKDF/
  authentication-hash construction matches the pinned protocol; Argon2id
  fails closed.
- EncString parsing and type-2 decrypt: MAC verified before CBC, one generic
  integrity failure, legacy and asymmetric forms refused, unknown types fail
  closed with ciphertext preserved.
- The quick-unlock construction (random access-controlled Keychain key plus
  AEAD-wrapped user key bound to the wrapped-key digest) matches
  `ARCHITECTURE.md`; enrollment change, rotation, and cancellation paths
  self-heal.
- `CLIProcessExecutor`: no shell, argument vectors only, environment
  allowlist, stdin null, bounded/counted stderr, output-limit termination,
  cancel/timeout escalation to SIGKILL; 1Password runner pins desktop-app
  authentication and scopes commands to a validated account identifier.
- `VaultwardenTransport`: ephemeral session, no cookies/cache/credential
  store, same-origin HTTPS-preserving redirect policy, error mapping that
  cannot carry the failing URL; base-URL policy rejects user info, query,
  fragment, and non-HTTPS outside explicit loopback development use.
- Origin approval precedes any credential-bearing request; 2FA challenge
  handling distinguishes user-completable providers; refresh-token
  replacement is atomic per record.
- Diagnostics: `AppLog` and `PerformanceTrace` emit only fixed allowlisted
  events; no logger interpolates user data.
- Session/generation discipline in `VaultSession` and `VaultSlot.close()`:
  generation advances before cancellation; late results fail the currency
  check.
