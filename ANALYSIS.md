# VaultSquire active product and engineering analysis

This is the living future-work backlog distilled from [`sol.md`](sol.md). The review snapshot remains immutable evidence; this file is pruned only after a change is merged and its applicable evidence passes. An open or green PR is **in review**, not done.

## Current implementation tracking

| Findings | Status | Pull request |
|---|---|---|
| VS-006, VS-017 | In review; macOS CI green; ready for review | [#34 — Constrain detail copy boundaries](https://github.com/L-K-M/VaultSquire/pull/34) |
| VS-007 | In review; macOS CI green; ready for review | [#35 — Fail partial CLI snapshot refresh publication](https://github.com/L-K-M/VaultSquire/pull/35) |
| VS-023, VS-043 | In review; macOS CI green; ready for review | [#36 — Add auto-lock inactivity preference](https://github.com/L-K-M/VaultSquire/pull/36) |
| VS-019, VS-028, VS-033, VS-051 | In review; CI pending at analysis update | [#40 — Unify in-memory vault search](https://github.com/L-K-M/VaultSquire/pull/40) |
| Multiple P0 boundaries | Existing broad overlapping work; not counted as done; currently conflicts with `main` | [#30 — Adversarial password-manager security hardening](https://github.com/L-K-M/VaultSquire/pull/30) |

**Completed and removed from this backlog:** none in this review cycle. The four implementation PRs are intentionally separate from this analysis PR and remain listed until merged.

- Review base: `0c05294` (`origin/main` at review start)
- Review date: 2026-08-11
- Scope: current clean-history repository only; no prohibited source or earlier history was consulted
- Host limitation: Linux. Repository/code inspection and portable shell checks only; no claim is made about Swift compilation, XCTest, AppKit/SwiftUI rendering, VoiceOver, signing, notarization, Keychain behavior, real CLI behavior, or performance on macOS.
- Existing work in flight: PR #30, **Adversarial password-manager security hardening**, overlaps many P0 findings below. It is not part of this review base, is currently reported `DIRTY`, and must not be counted as completed until it is reconciled, reviewed, green, and merged.

## Executive assessment

VaultSquire has an unusually thoughtful set of controlling documents, clean-room rules, synthetic tests, provider boundaries, and fail-closed intentions. The no-shell CLI executor, exact provider identities, token/clipboard handling, URI policy, Keychain-bound Touch ID design, and explicit release block are strong foundations.

The implementation is nevertheless much less complete than the top of `README.md` suggests. It is an advanced prototype, not yet a dependable general-use password manager. Several production capabilities are enabled without their own documented gates having passed; the real encrypted database is still a protocol seam plus flat AEAD files; Argon2id is unavailable; initial login does not require a complete first snapshot; sync omits the controlling revision/rotation transaction; offline CLI reads are not wired into the app; archive has no browse/unarchive flow; search is a synchronous substring filter; and logout/account removal does not exist.

The most important action is not aesthetic polish. It is to make the shipped capability surface honest and fail closed, then fix lifecycle/snapshot correctness, then make search/projection work scale. High-value visual polish should follow on a real Mac with screenshots and accessibility passes.

## Priority legend

- **P0** — unsafe claim, data-loss/security risk, or controlling invariant violated; disable or fix before anyone treats the feature as usable.
- **P1** — major correctness, performance, or core-journey gap.
- **P2** — material usability, accessibility, layout, or product-quality issue.
- **P3** — enhancement or delight idea.
- Confidence is based on the reviewed code, not unrun macOS behavior.

## Findings

### A. Capability, security, and correctness

#### VS-001 — Untested CLI releases are enabled in production — P0, high confidence

`ProtonCLIVersionGate.production` admits 2.2.3–2.2.6 (`VaultSquire/Providers/Proton/ProtonCLIVersionGate.swift:40-46`) and `OnePasswordCLIVersionGate.production` admits five stable releases (`VaultSquire/Providers/OnePassword/OnePasswordCLIVersionGate.swift:46-54`). The comments explicitly say none was exercised against a live CLI in this environment. The controlling policy says exact versions/build identities and schemas are admitted only after testing; an empty allowlist is the safe pre-evidence state. This makes dormant/research-grade adapters appear production-capable.

Recommendation: make production allowlists empty until immutable live-contract evidence exists; retain injected allowlists for fake-executor tests. Keep 1Password hidden behind its separate terms and TTY-less authorization gates.

Status: PR #30 says it addresses this; pending, not done.

#### VS-002 — Vaultwarden writes are enabled before their release gates — P0, high confidence

`VaultwardenAccountService.capabilities` exposes create, update, and archive, and the toolbar invokes them. The repository does not contain the required pinned-server cross-client round trips, two-client conflict/ambiguity matrix, or archive ADR/evidence. Update also lacks the required latest-record preflight and complete conflict UI; it relies on the last synced revision and reduces a conflict to “sync, then make it again.”

Recommendation: remove production mutation capabilities until each operation's positive, negative, cancellation, ambiguity, leakage, and official-client tests pass. Re-enable one operation per reviewed PR. Preserve drafts in memory and reconcile authoritatively after every success or ambiguity.

Status: PR #30 says it disables remote mutation capabilities; pending, not done.

#### VS-003 — Initial sign-in can report success without a complete first snapshot — P0, high confidence

`AddAccountModel.store` saves credentials and calls `persistAfterLogin`; `VaultwardenAccountService.persistAfterLogin` creates an empty seed snapshot and best-effort saves it (`VaultSquire/Providers/Vaultwarden/VaultwardenAccountService.swift:80-113`). If the login response already contains a wrapped key, first unlock presents that empty snapshot and only starts sync afterward. The controlling journey requires first sync validation and atomic snapshot persistence before publishing account success/open state.

Impact: a user can receive “Account Added,” then open an empty or stale vault; a failed first sync leaves credentials plus an apparently configured account without a validated vault.

Recommendation: make account addition one transaction: authenticate, fetch and validate a complete sync, seal it, persist credentials/descriptor with rollback, then report success. Never publish an empty cache as a successful vault.

#### VS-004 — Sync is not the specified revision-gated atomic algorithm — P0, high confidence

`VaultwardenSyncService.sync` refreshes once and fetches `/sync` once; it does not read account revision before/after, skip no-change syncs, retry a raced candidate, or force repair categories (`VaultSquire/Providers/Vaultwarden/Network/VaultwardenSyncService.swift:50-94`). `merge` can accept ciphers and organization keys while refusing changed wrapped user/private keys (`:96+`), producing a snapshot assembled across incompatible hierarchy generations instead of persisting `reauthenticationRequired` and retaining the complete prior snapshot.

Recommendation: implement the full controlling state transition: reject secret operations and invalidate session generation first; compare all bootstrap material; persist the marker without replacing the current generation; invalidate quick unlock; and clear the marker only in a complete reauthentication + fresh-snapshot transaction. Add before/after revision checks and bounded retry.

Status: PR #30 claims a marker/hierarchy fix; pending. Its large diff needs focused review against this exact invariant.

#### VS-005 — Lock does not reliably stop or suppress write completion — P0, high confidence

`AppModel.save` and `archive` capture unlocked material, start tracked tasks, and publish global `isWriting`/`writeError` after awaiting without checking the vault generation (`VaultSquire/App/AppModel.swift:755-797`). Cancellation is cooperative; `SerialOperationGate` intentionally lets an in-flight operation finish. A lock can therefore leave a network mutation running with captured key material, and the late completion can update UI state after the generation changed.

Recommendation: reject new writes synchronously during lock, check cancellation/generation before every network phase and before publication, and reconcile any already-ambiguous request rather than claiming it was not saved. Write tasks need different semantics from permitted ciphertext-only locked sync.

#### VS-006 — Secret text selection bypasses the clipboard service — P0, high confidence

Revealed secret text has `.textSelection(.enabled)` in `VaultItemDetailView` (`VaultSquire/Features/Vault/VaultItemDetailView.swift:118-126`). Selecting and copying through native text actions bypasses `ClipboardService`, so no concealed/transient hint, ownership tracking, 30-second expiry, or lock clear is applied.

Recommendation: secret fields must not expose native text-selection/copy. Keep the explicit copy action as the only copy route and negative-test menu, keyboard, accessibility, and Services paths.

Status: likely overlaps PR #30's clipboard hardening; verify explicitly before considering done.

#### VS-007 — A partial CLI refresh replaces the last complete snapshot — P0, high confidence

Both CLI services catch a failed per-vault list and `continue`, then seal the remaining items as authoritative (`ProtonAccountService.swift:150-174`; `OnePasswordAccountService.swift:226-261`). A transient authorization/read failure silently removes a whole vault's items from the new offline snapshot.

Recommendation: fail the candidate and retain the old complete snapshot, or introduce an explicit partial-snapshot type that cannot replace a complete generation and is visibly presented as partial. The former is safer and simpler.

Status: already recorded as R7 in the existing adversarial review; still open on this base.

#### VS-008 — CLI stderr and pipe queues are not actually bounded — P0, high confidence

The executor uses unbounded `AsyncStream` buffering for stdout and stderr (`CLIProcessExecutor.swift:340-341`). Stdout is capped only after queued chunks reach the collector; stderr has no byte limit at all and increments an `Int` (`:256-277`). A malicious/replaced CLI can enqueue data faster than actor draining, causing memory growth despite the documented “bounded I/O” claim.

Recommendation: use finite buffering/backpressure, cap stdout and stderr independently, terminate on either limit, use overflow-safe counters, and erase captured stdout on every failure/cancel path.

Status: PR #30 says it adds finite queues and strict bounds; pending, not done.

#### VS-009 — CLI executable identity is not authenticated — P0 release blocker, high confidence

The locators resolve paths and version-gate strings, but do not enforce code signature/team/notarization identity. A replaced binary can print an allowed version. This is already documented as open evidence, but conflicts with the README's “implemented” tone.

Recommendation: keep CLI providers unavailable in production until selected-path approval, resolved-path persistence, signature/team/notarization inspection, replacement detection, and clean-Mac tests pass. Do not silently reject legitimate unsigned package-manager builds; display and require explicit policy approval.

#### VS-010 — CLI cached offline unlock is advertised but not wired or user-presence gated — P0/P1, high confidence

Both services can load cached snapshots, but `AppModel.openProton` and `openOnePassword` always invoke live refresh and never fall back to `cachedSnapshot`. Their keys come from plain `DeviceDataKeyStore`, not a user-presence-bound Keychain read. Thus “offline read” exists as storage code but not as a safe product journey.

Recommendation: either remove offline CLI claims or implement a session-owned, user-presence-bound key release, cached unlock, key-loss discard/refetch behavior, stale indicator, and lock tests.

#### VS-011 — Reprompt items are not reverified — P0 release blocker, high confidence

The model preserves `reprompt`, but detail/draft flows do not require a newly entered master password. This was already recorded as R2. Quick unlock or an already-open session must not satisfy reprompt.

Recommendation: hide reveal/copy/edit capabilities until a short-lived, item-scoped re-verification succeeds; use a fresh secure field and generic failure.

#### VS-012 — No secure logout/account-removal transaction — P0 release blocker, high confidence

The app can add and lock accounts but has no UI/use case to remove one or log out. Therefore users cannot trigger the required deletion of refresh/remember tokens, descriptors, cache files, biometric envelopes, CLI cache keys, clipboard ownership, and decrypted state.

Recommendation: design one idempotent per-account removal transaction, lock/invalidate first, cancel all work, wipe every store/key, and report partial cleanup without reopening the account. Add artifact post-condition tests.

#### VS-013 — Argon2id accounts are unsupported while product copy implies broad Vaultwarden support — P1, high confidence

`VaultwardenKeyDerivation.deriveMasterKey` validates Argon2id but always throws `argon2idUnavailable`. The UI correctly reports unsupported, but README's top-level “implemented end to end” framing hides a common compatibility boundary.

Recommendation: either prominently state PBKDF2-only in product status or adopt an Argon2 dependency only after the full dependency gate, memory/cancellation bounds, vectors, and provenance pass.

#### VS-014 — Flat AEAD cache is not the planned encrypted database — P1, high confidence

Production uses whole-file JSON + ChaCha20-Poly1305 cache files. `EncryptedStore` is a protocol and test double; GRDB/SQLCipher remains deferred. Whole-snapshot decode/encode scales poorly, gives no row-level updates, and cannot satisfy the documented WAL/migration/crash evidence.

Recommendation: do not describe Workstream 5 storage as complete. Run the dependency spike, then wire one transactional store. Until then, cap supported vault size and measure full-file memory amplification.

#### VS-015 — Account email is persisted in UserDefaults despite the privacy model — P1, medium-high confidence

`AccountDescriptorStore` writes `AccountDescriptor.email` and server display to preferences (`VaultSquire/Persistence/AccountDescriptorStore.swift:7-45`). The architecture's allowed preference row names provider kind, server base URL, and non-secret preferences, while the security plan treats account identifiers as high sensitivity.

Recommendation: store only an opaque account key and a deliberately reviewed display label in preferences; obtain email from the sealed cache after local authorization, or explicitly reconcile the controlling documents if locked-screen identification is judged worth this disclosure.

#### VS-016 — Site-icon requests may leave the approved site origin — P1, high confidence

`SiteIconFetcher` uses a default `URLSession` delegate, so redirects are followed automatically. The feature promises each icon is fetched only from that site's own origin, but a site can redirect `/favicon.ico` to an aggregator/CDN/tracker. Image decoding also occurs on the main actor after fetch and a compressed image under 256 KiB can still have huge dimensions.

Recommendation: reject cross-origin/downgrade redirects; validate MIME/type and pixel dimensions with ImageIO before full decode; decode/downsample off the main actor; cap concurrent icon fetches; clear in-flight work on disable/lock.

Status: PR #30 touches icon privacy/resource boundaries; verify redirect and decode-bomb handling explicitly.

#### VS-017 — URI confirmation copy makes a false privacy promise — P1, high confidence

The dialog says “Nothing from this vault is sent with it,” then opens the full saved URL (`VaultItemDetailView.swift:30-44`). The URL itself came from the vault and its path/query may contain identifiers or secrets; the destination/browser receives it.

Recommendation: say that the complete saved address will be opened and may be shared with the destination/browser; continue emphasizing the effective scheme/host. Consider warning on nonempty query/user-sensitive-looking fragments.

#### VS-018 — Error copy can make ambiguous writes sound safely unsaved — P1, high confidence

A transport failure maps to “The change was not saved,” but a connection can fail after the server commits. The controlling write policy requires ambiguity reconciliation before this claim or retry.

Recommendation: classify pre-send versus ambiguous failure. For ambiguous outcomes, retain the draft, block retry, run an authoritative read, then report committed/not committed/still unknown.

#### VS-049 — Session expiry is displayed as an error instead of a security-state transition — P0, high confidence

Vaultwarden sync and writes return `sessionExpired`, but `AppModel` leaves the decrypted vault open and records only `syncError`/`writeError`. The richer `VaultSession.reauthenticationRequired` model is not wired into the production `VaultSlot` flow. A revoked refresh token or server-side logout therefore leaves already-decrypted content visible and allows repeated doomed operations.

Recommendation: route every terminal auth failure through one account transition: invalidate generation, reject new secret operations, lock and clear plaintext, persist reauthentication-required without deleting the last good encrypted cache, and present a focused reauthentication action.

#### VS-050 — Local token/cache persistence failures are reported as network success — P0/P1, high confidence

The write path ignores rotated refresh-token replacement failure, and sync ignores both token replacement and `vaultCache.save` failure while returning the newly fetched snapshot as success (`VaultwardenAccountService.swift:396,455-460`). The UI can show fresh data that was never durably sealed and the next launch can reopen older state or lose the rotated token.

Recommendation: make local credential and snapshot publication part of the operation's success boundary. Preserve the prior generation on failure, report a typed local-storage error, and distinguish “remote operation may have committed” from durable local success.

#### VS-051 — Quick Search retains decrypted projections after dismiss and lock — P0, high confidence

`QuickSearchPanelModel.clear()` removes only `query`; it does not release `items` or `onOpen`. The panel/controller are retained for process lifetime. Dismissing on all-vault lock therefore hides but retains titles, usernames, hosts, folders, and callback state. Locking only one of multiple vaults does not dismiss or refresh the panel at all, so that locked vault's rows can remain visible and actionable in an already-open panel.

Recommendation: add a release/reset operation that drops query, items, result index, selection, and callbacks; invoke it on dismiss and lock. While visible, update the panel from generation-aware session changes so a per-vault lock immediately removes that vault's results. Add negative tests for all-lock and one-of-many lock.

### B. Performance and stuttering

#### VS-019 — Search is synchronous O(n) work on the main actor for every edit — P1, high confidence

Both browser and Quick Search compute case-insensitive substring filters in view-facing computed properties (`QuickSearchPanelModel.swift:22-27`; `VaultBrowserView.swift:33-38`). There is no debounce/cancellation, normalized index, result cap, quoted-term parser, deterministic ranking, or background computation. View body accesses can recompute results multiple times.

Impact: typing can stutter at 10k–100k items, exactly where the controlling 75 ms render and 250 ms/100k search gates apply.

Recommendation: build a generation-bound in-memory normalized index incrementally off the main actor; parse once per query; cancel stale searches; publish at most a screenful plus a count; rank exact title, title prefix, username/host prefix, then contains. Add composed/decomposed Unicode, punctuation, quotes, and 100k tests.

#### VS-020 — The main list repeatedly sorts and regroups complete collections — P1, high confidence

`AppModel.items` flattens and sorts every access (`AppModel.swift:139-148`) even though provider projections are often already sorted. Sidebar `groups` scans all items and is requested repeatedly while building vault rows. Filtering asks for `appModel.items` again. These are main-actor computed properties tied to SwiftUI invalidation.

Recommendation: publish immutable per-scope sorted snapshots and group summaries only when sessions/scope change; use stable IDs; never derive 100k-item aggregates inside view body recomputation.

#### VS-021 — Sync projection/decryption runs synchronously on the main actor — P1, high confidence

On Vaultwarden sync success, `AppModel` calls `service.projections` and `decryptFolderNames` inside the main-actor mutation (`AppModel.swift:823-836`). That decrypts, maps, and sorts the whole vault. Biometric unlock also calls the synchronous full projection path from the main actor.

Recommendation: generation-bound detached/background projection with bounded batches; publish the first 100, then incremental sorted inserts/index updates. Lock must invalidate before late batch publication.

#### VS-022 — No incremental/no-change sync path — P1, high confidence

Every Vaultwarden sync refreshes a token, downloads `/sync`, decrypts/rebuilds all projections while open, and rewrites a whole sealed file. CLI providers run one process per vault on every refresh. There is no revision no-op or changed-ID invalidation.

Recommendation: first implement the documented Vaultwarden revision check and changed-projection invalidation. For CLIs, retain full refresh but show progress by vault, serialize once per account, and avoid unnecessary version probes within one refresh session.

#### VS-023 — Mouse movement can enqueue a main-actor task per event — P2, high confidence

The local event monitor creates `Task { @MainActor ... }` for every mouse-moved/scroll event (`AutoLockController.swift:106-113`). Mouse movement can generate a high event rate.

Recommendation: update activity directly on the main run loop or coalesce/throttle to one pending update. Re-arm the inactivity timer only when the preference changes, not on each event.

#### VS-024 — Whole-file caches amplify memory and write cost — P2, high confidence

A sync holds response bytes, decoded models, re-encoded plaintext JSON, sealed bytes, and projections at once. The cache allows a 128 MiB sealed file, so peak memory can be several times that. Every small change rewrites the whole file.

Recommendation: measure peak allocations with 10k/100k synthetic vaults, temporarily lower honest supported limits, then move to row-level encrypted transactional storage.

#### VS-025 — TOTP redraws every second per visible detail — P3, high confidence

One `TimelineView` per TOTP is acceptable for one detail, but the code recomputes HMAC every second even though the code changes only at period boundaries.

Recommendation: update countdown cheaply each second and recompute only when the counter changes. Low priority unless Instruments shows cost.

### C. Missing core product features

#### VS-026 — Archived and trashed items cannot be browsed or restored/unarchived — P1

The decryptor drops both states entirely. There is no Archived or Trash filter, no unarchive, and no state badge. Archiving makes an item disappear with no in-app recovery path, despite the plan requiring distinct filters and README claiming archive support.

#### VS-027 — Favorites are written but not useful — P2

The editor exposes Favorite, but list rows show no star and the sidebar has no Favorites scope/filter. The feature currently changes remote state without improving retrieval.

#### VS-028 — Search semantics are far below the planned product — P1

No accent normalization, token/prefix matching, quoted terms, ranking, archived-filter awareness, typo tolerance, or “recently used” signal. Browser search and Quick Search duplicate logic and can drift.

#### VS-029 — No password generator or password-history UI — P1/P2

The create/edit form expects manual passwords. A high-quality password manager needs length/character/word controls, strength feedback, and a one-click fill action, but generator adoption must get its own threat/tests and writes must first be admitted.

#### VS-030 — No account management — P1

No rename, reorder, provider diagnostics, reconnect, remove/logout, cache age/size, or per-account lock settings. Multiple accounts appear, but cannot be managed after addition.

#### VS-031 — Offline/stale state is not honestly surfaced — P1

The toolbar shows only a relative last-sync time or first error. It does not distinguish offline, stale cache, session expired, reauthentication required, partial CLI state, or “never completed initial sync.”

#### VS-032 — Global Quick Search is not global or configurable — P1/P2

The command shortcut is an app menu shortcut, active when VaultSquire is active; no global registration exists. Settings presents “Command-Shift-Space” as a value, not a control, while nearby copy claims configurability is gated. Add shortcut recording, conflict detection, disable option, and accessibility behavior only after the dependency/adoption gate.

#### VS-033 — Quick Search is not a keyboard-first command palette yet — P1/P2

There is no explicit selected row, arrow-key loop, source-vault badge, item icon, match highlighting, copy username/password shortcuts, or action hints. Return always opens the first result, not a navigated selection.

#### VS-034 — Core item-type support is incomplete — P1

Vaultwarden reads login/note/card/identity but SSH keys are “unsupported”; writes only handle login. Proton/1Password map only lossy documented fields. The UI needs honest unsupported placeholders with provider/version reasons rather than generic “Item.”

#### VS-035 — No attachment, AutoFill, Safari, passkey, import/export, or Sends support — planned/deferred

These are valid future features, not bugs. AutoFill is the highest user-value next platform feature after storage/session correctness; attachments and export carry greater secret/file risk and should remain later.

### D. Visual, layout, and interaction quality

These are code-evidenced concerns but require screenshot and accessibility validation on a real Mac before implementation is called complete.

#### VS-036 — Fixed sheet/settings sizes will clip at larger text and with many accounts — P2, high confidence

Add Account is fixed to 420 pt wide with no outer scroll; its 1Password account list can grow. Edit is fixed 460×560. Settings is fixed 540×340 while containing long privacy prose. Larger accessibility text, localization, or several accounts can overflow.

Recommendation: use minimum/ideal sizing, scrollable content, sensible max width, and test narrow/large-text/localized states.

#### VS-037 — Visual language is split between a bespoke locked shell and generic post-unlock forms — P2

The dark “identity rail” has personality, but the main vault, settings, add-account, and editor mostly use default controls without a shared material, spacing, typography, badge, empty-state, or animation system. It reads as a prototype assembled from native defaults rather than one high-value product.

Recommendation: define a small original design system: spacing scale, content widths, sidebar/list row metrics, semantic status chips, field cards, provider-neutral category symbols, and restrained blue/brass accent derived from the original icon. Preserve native macOS behavior rather than skinning every control.

#### VS-038 — The icon is too detailed for small sizes — P2, visual gate already open

The canonical icon is attractive at 1024 px but contains fine bolts, reflections, chainmail, multiple keyholes, and a helmet/vault combination. At 16–32 px it is likely to become noisy and lose silhouette. The repository already records small-size review as open.

Recommendation: do not replace the canonical source casually. Have an original designer produce reviewed small-size simplifications/optical variants under the provenance process, then regenerate hashes and inspect at 1×.

#### VS-039 — Toolbar is crowded and weakly contextual — P2

Add, Edit, Archive, Sync, and Lock All are always present as equal-weight toolbar items, mostly disabled depending on state. This creates visual noise and weak hierarchy.

Recommendation: keep Add and Sync primary; put item-specific Edit/Archive in detail/context menus and the main Item menu; keep Lock visually distinct and always keyboard accessible. Explain unavailable provider actions in context rather than only disabling them.

#### VS-040 — Detail fields lack action feedback and compact structure — P2

Copy buttons provide no confirmation/countdown; labels are uppercase and every field gets a full divider; long notes/URLs can dominate. Secret reveal state has no automatic re-conceal timer.

Recommendation: grouped field cards or inset sections, copy checkmark/toast (“Copied • clears in 30s”), optional countdown ring, reveal auto-hide, truncation with expansion for long values, and consistent action menus. Never put the secret itself in feedback/accessibility text.

#### VS-041 — Status relies on subtle color and tiny secondary text — P2

Open locks use accent color, success uses green, failures red, and sync errors can collapse into a one-line toolbar capsule. Ensure every status has icon + text, adequate contrast/increased-contrast behavior, and a discoverable details action.

#### VS-042 — Empty/error states do not provide the next best action — P2

“No vault is open” says select a vault, but All Vaults can be selected with everything locked. Empty search has no clear-search button or suggestions. Sync error in the blank detail does not expose Retry/Diagnostics. Locked CLI panes send users to a terminal without install/help links.

Recommendation: action-oriented empty states: Unlock Vault, Open All Available, Clear Search, Retry Sync, Show Supported CLI Setup, and Learn Why This Is Read-only.

#### VS-043 — Settings copy is internally contradictory — P2

It displays a fixed shortcut and says configurable shortcut/lock policy are enabled only after tests pass, while auto-lock is already enabled and its preference key has no UI. Replace placeholder prose with actual controls or an explicit “Not yet configurable” status.

#### VS-052 — CLI secret hydration has no visible loading/failure state — P2, high confidence

`AppModel.isHydrating` exists but has no view call site. Opening a Proton/1Password item initially shows only summary fields, so a user cannot tell whether password fields are loading, absent, unsupported, or failed. A failed on-demand read silently looks like an item with no secret.

Recommendation: show an inline, non-blocking “Loading protected fields…” state, then a retryable provider-specific failure or an explicit “No protected fields” result. Keep prior summary fields visible and clear status on lock/generation change.

#### VS-053 — Unlock and error focus are not keyboard/accessibility-first — P2, high confidence

The default `.allVaults` scope makes a sole Vaultwarden password field require selecting its sidebar row first, and the field has no `@FocusState`. Errors are mostly red text without focus movement, announcement, or a non-color symbol. This slows every launch and risks silent failure for VoiceOver users.

Recommendation: when exactly one configured vault is locked, select it automatically; focus its secure field when the pane becomes active; on validation/auth failure move accessibility focus to a labeled error summary while preserving safe input behavior.

#### VS-054 — Deterministic monogram colors are not contrast-safe — P2, high confidence from color math; visual validation owed

`ItemIconView` uses a fixed HSB brightness/saturation hue as foreground over an 18% tint of the same hue. Yellow/green portions of the 3,600-value hue range can have poor light-mode contrast, so specific sites receive a permanently hard-to-read badge.

Recommendation: derive separate light/dark foreground and background tones with a minimum contrast target, add a pure color-math test over all hue buckets, and validate increased-contrast mode on macOS.

### E. Test, documentation, and delivery issues

#### VS-044 — README overstates implementation readiness — P0/P1, high confidence

The README says providers and writes are implemented end to end, offline cache is usable, archive/write support exists, and multiple vaults operate. It underplays empty live CLI evidence, Argon2 absence, non-production storage, absent offline CLI UI, incomplete initial sync, no unarchive/filter, and unmet mutation gates.

Recommendation: split “code present,” “fake-boundary tested,” “live-contract tested,” and “release admitted.” Never label a capability supported merely because code exists.

#### VS-045 — Workstream/delivery status is stale and contradictory — P1

`DELIVERY.md` says Workstreams 4+ await sequential PRs; Workstream 4/5 records say slices are implemented; README describes later work as done. The status model is difficult to trust.

Recommendation: one machine-readable feature/evidence manifest should drive README tables, release gating, and UI capability admission.

#### VS-046 — UI coverage stops near the shell — P1

UI tests cover the locked shell, panel focus, settings, and add-account sheet, but not successful login/2FA, unlock, list/detail, reveal/copy, create/edit conflict, archive, per-vault lock, search navigation, large text, or error focus. Many negative capability paths are unit-only.

#### VS-047 — Performance fixtures measure presentation, not the real corpus path — P1

The Quick Search performance fixture does not prove query/index/render at 10k/100k, and the current synchronous search implementation has no blocking corpus benchmark. Add release-mode generated corpora and signposts around query normalization, ranking, publication, and row render.

#### VS-048 — Portable repository verification is environment-fragile — P2

`./scripts/check-repository.sh` failed here because `python3` is absent after correctly reporting the release block. This is not a product defect, but local verification should preflight tools with an actionable message or document the required environment clearly.

## Recommended implementation order

1. **Merge or supersede PR #30 safely.** Rebase/split it as needed; review P0 boundaries independently. Do not stack broad visual work onto it.
2. **Make capability admission honest:** empty live CLI allowlists; hide 1Password until terms/TTY gates; disable writes until evidence.
3. **Fix snapshot/session correctness:** initial full sync transaction, hierarchy-rotation marker, revision checks, partial CLI snapshot rejection, write-on-lock/ambiguity handling, secure logout.
4. **Fix secret escape paths:** native selection copy, user-presence-bound CLI cache keys, executable identity, finite process queues.
5. **Wire a real encrypted transactional store** after dependency approval.
6. **Build one shared off-main search/index pipeline** and bounded incremental projection; then measure 10k/100k on named Macs.
7. **Complete browse fundamentals:** Archived, Trash, Favorites, stale/offline status, account management.
8. **Polish the macOS UX** with screenshot/VoiceOver/large-text evidence.
9. **Add high-value platform features:** global Quick Search, password generator, then AutoFill.

## High-confidence small/medium PR candidates

These are suitable for separate branches once overlapping PR #30 changes are reconciled:

1. Reject partial Proton/1Password snapshots (VS-007).
2. Remove secret native selection/copy and negative-test it (VS-006).
3. Correct URI privacy copy (VS-017).
4. Add an actual auto-lock preference and coalesce activity events (VS-023/043).
5. Add same-origin redirect enforcement and safe icon downsampling (VS-016).
6. Centralize normalized ranked search with cancellation/result caps (VS-019/028/033) — medium-sized, should be one coherent PR, not scattered view tweaks.
7. Make settings/add-account/edit layouts scroll and adapt to text size (VS-036).
8. Add copy feedback with no secret-bearing accessibility output (VS-040).

Do **not** implement Argon2, SQLCipher, global-shortcut libraries, AutoFill, attachments, or provider writes without their specific dependency/security/adoption gates.

## Original, delightful, and quirky ideas

These are concepts, not commitments. They must remain original and pass privacy/accessibility review.

- **Squire Strip:** a compact, keyboard-only Quick Search footer showing safe actions: `↩ Open`, `⌘U Copy user`, `⌘⇧C Copy password`, plus the source vault. Never preview a secret.
- **Clipboard “torch”:** after an explicit copy, the copy icon becomes a tiny shrinking ring for 30 seconds, then quietly returns to normal. It communicates expiry without retaining or rereading the value.
- **Vault portcullis lock:** on lock, rows collapse into a single restrained vertical wipe (disabled under Reduce Motion), followed immediately by state cleanup—not an animation that delays security.
- **Provider truth badges:** tasteful chips such as `Offline snapshot • 2h old`, `Read-only via CLI`, or `Reauthentication needed`, making provider asymmetry feel intentional rather than broken.
- **Privacy receipt:** a local, ephemeral panel listing what VaultSquire contacted during the current session by category and count only (“Your server: 3 requests; provider CLI: 2 runs; site icons: 0”), with no domains/account IDs and nothing persisted.
- **Hold-to-reveal option:** press and hold Space while a secret field is focused; release to conceal. Keep click reveal as an accessibility alternative and never surprise VoiceOver.
- **“Why unavailable?” menus:** disabled actions remain inspectable through a nearby info affordance: “Editing is unavailable because this provider is read-only in VaultSquire 0.1.”
- **Command-palette verbs:** Quick Search can recognize local commands after a `>` prefix—`> lock all`, `> sync work`, `> add account`—without sending queries anywhere or indexing secrets.
- **Duplicate-title disambiguation:** use source-vault chips, host, and stable monograms; never leak full account emails in All Vaults unless the user opts in.
- **Calm stale-state weather:** a tiny non-color status glyph that moves from fresh → aging → stale → offline, with exact time and cause in its help popover.
- **Original small-size icon family:** preserve the canonical art at large sizes, but commission simplified, optically tuned 16/32/64 px variants using only the helmet/keyhole silhouette and blue/brass split.

## Verification performed

- Read the controlling documents in required precedence and the provider/implementation/security reports.
- Inspected the complete current source/test inventory (about 25k Swift lines), with focused tracing of app/session state, auth/sync/write paths, process execution, caches/Keychain, search, clipboard, icon fetching, and primary SwiftUI/AppKit surfaces.
- Inspected current branch/remotes and open PRs. PR #30's checks were green at inspection, but its merge state was `DIRTY` and it is not in the review base.
- `git diff --check`: no issue observed on the clean review base.
- `./scripts/check-repository.sh`: could not complete because this Linux environment has no `python3`; no macOS claim is made.

## Definition of “done” for future entries

An item leaves the future analysis only when its PR is merged and all applicable positive, negative, cancellation, ambiguity, leakage, accessibility, and performance evidence is linked. “Code exists,” “unit test over a fake passed,” and “open PR is green” are not synonymous with supported or done.
