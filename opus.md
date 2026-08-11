# VaultSquire — product, correctness, and performance review

Reviewer: Claude (Sonnet 5), reading the tree at `main` 0c05294 plus the open
PR landscape as of 2026-08-11 ~21:20 UTC. Four parallel sub-reviews covered
the Vault/Quick Search UI, the AddAccount/LockedShell/Settings UI, the
App/Domain/Persistence/Infrastructure layer, and the three provider verticals,
cross-checked against my own direct reading of the core files.

## Method and limits

This environment is Linux with no Swift/Xcode toolchain, so nothing here is
compile-verified, run, or visually inspected. Every claim is from source
reading; `scripts/ci.sh` (the pinned-Xcode macOS lane) is the actual gate for
compilation, tests, signing, and visual/accessibility truth.

The codebase has already been through two rounds of adversarial security
review (`docs/security-review/2026-08-11-adversarial-review.md`, PR #30), so
this review deliberately stays off crypto/Keychain/auth-boundary ground and
focuses on what the user experiences: correctness bugs, responsiveness,
missing features, layout, and polish.

## Concurrent work — read this first

This repository had heavy simultaneous activity from other agent sessions
while this review was written, including what looks like a parallel run of
the same "review the app, write opus.md, implement the best parts" task
(branch `opus/review-document`, PR #37, same git identity). That sibling
review independently found much of the same ground — which is good
convergent signal — and its author already opened implementation PRs for the
highest-value, most obvious gaps:

| PR | What it does |
| --- | --- |
| #34 | Constrains detail-view copy boundaries |
| #35 | Fails (rather than silently partial-seals) a CLI refresh that can't read every vault |
| #36 | Adds a real auto-lock inactivity preference to Settings |
| #38 | Reconciles browser selection with Quick Search, query, and sync |
| #39 | Lets a Dock click reopen the main window |
| #40 | Unifies browser + Quick Search search with bounded in-memory indexing, arrow-key nav, ranking |
| #41 | Invalidates cached CLI item secrets on sync (stale-password bug) |
| #42 | Adds an offline password generator with a reveal toggle |

Also open: #30 (a very large adversarial security/correctness pass touching
almost every file), #31 (honest Settings copy about the lock policy), #32
(clear cached site icons on per-vault lock), #33 (a sibling
review/ANALYSIS.md effort from yet another session).

**Findings below that duplicate ground already covered by an open PR are
marked `[covered by #NN]` and are not re-implemented here.** Everything else
is either genuinely new or complementary. My implementation choices (§8) were
picked specifically to avoid stepping on this list.

## Verdict

The engineering is unusually careful for a from-scratch codebase: the
generation-counter discipline around lock/cancel is applied consistently, the
provider boundary is real, capability gating happens in the use case rather
than only in a disabled button, and the in-code comments consistently explain
*why* a decision was made rather than just what the code does. Nothing here
reads as sloppy or rushed.

What's missing is mostly the last-mile product work — and a good chunk of it
is already being closed out by the sibling PRs above. What's left after
subtracting that work is: two real correctness bugs in less-traveled paths
(2FA cancellation, CLI-provider offline fallback), one meaningful performance
bug nobody else flagged (a full vault is decrypted **twice** on every
unlock), one scope regression against `PLAN.md` (archived items are
permanently unreachable once archived), a smaller scope gap (Vaultwarden
collections are never decoded), and a handful of contained, low-risk
completeness/polish items.

---

## 1. Bugs

### 1.1 A full Vaultwarden vault is decrypted twice on every unlock — the single highest-value fix in this document

`AppModel.swift:351-370` (`finishOpen`) sets `session.items` from the vault
`unlock()` already decrypted, then unconditionally calls `syncNow(account)`.
`AppModel.swift:809-843` (`syncNow`, Vaultwarden branch) then unconditionally
calls `service.projections(keyring:snapshot:)` again on whatever the network
sync returned — a full AES-CBC decrypt + HMAC verify of every cipher's title,
username, and URIs, run synchronously **on the Main Actor** (`mutate` is a
non-`async` method on `@MainActor final class AppModel`, called with no
`await` inside the task, so there is no possible executor hop away from the
UI thread here).

`service.unlock()` reads the **local sealed cache** (`vaultCache.load`), not
the network — so the subsequent `syncNow` network round-trip is not itself
redundant, it's the correct "check for server-side changes" step. But the
code re-decrypts and rebuilds the whole item list even when the server
returns byte-identical data, which is the common case for "just opened the
app, nothing changed since last sync." This also directly contradicts the
explicit performance gate in `ARCHITECTURE.md`/`PLAN.md`: *"Incremental sync
with no revision change | Encrypted 10,000-item snapshot | No cipher
decryption or list rebuild."* Every unlock pays this cost twice; every manual
sync and every post-write sync pays it once more, unconditionally, forever.

**Fix implemented (§8.A):** `VaultwardenVaultSnapshot` and
`VaultwardenCipherModel` are already `Hashable`/`Equatable`, so `syncNow`'s
Vaultwarden branch can cheaply compare the freshly synced `ciphers`/`folders`
against what's already loaded and skip the decrypt+projections+folder-name
rebuild when nothing changed, while still updating `lastSyncedAt` and the
stored snapshot. This is a small, mechanical, low-risk change — no actor
restructuring, no new concurrency surface — confirmed safe because the
`ProviderCacheReference.generation` field the skipped rebuild would have
bumped is purely informational (used nowhere for correctness or security
comparisons; grepped confirmed).

Confidence: high. This is a real, structurally-guaranteed cost, not a
maybe.

### 1.2 2FA "Back" does not cancel the in-flight verification request

`AddAccountModel.swift` / `TwoFactorChallengeView.swift:73`. `Button("Back")
{ model.returnToForm() }` has no `.disabled(model.phase == .connecting)`
guard, and `returnToForm()` never cancels the active task. Because
`submitTwoFactor()` runs synchronously up to the `await
authenticator.completeTwoFactor(...)` call, a user can tap Verify, then tap
Back while the network call is still in flight. The abandoned task keeps
running: on success it silently stores credentials in the Keychain, calls
`onAccountConfigured`, and flips the sheet to "Account Added" out from under
the user who thought they'd backed out; on failure it flips back to the
challenge screen the user just left, with a stale error. `Task.isCancelled`
guards exist elsewhere in this file but nothing ever calls `.cancel()` on
this path.

Confidence: high. Not covered by any open PR (none of them touch
`AddAccountModel.swift`).

### 1.3 Archived Vaultwarden items become permanently unreachable, contradicting `PLAN.md`'s stated scope

The toolbar "Archive" action works, but `VaultwardenAccountService` has no
`unarchive`/`restore` function at all (only `archive`), and
`VaultwardenItemDecryptor.projection` (`:106`) filters out every archived
cipher from every projection with no "Archived" scope or filter anywhere in
the sidebar. Once a user archives an item in VaultSquire, it is gone from the
app permanently — recoverable only through the official Bitwarden web vault.
`PLAN.md`'s scope table explicitly includes *"Archived-state reads: parse
per-user `archivedDate`, keep archived items out of default browse/search,
and **offer an explicit Archived filter**."* Only the exclusion half is
implemented; the filter and any way back are missing. Worse, the toolbar
button has no confirmation dialog, so this is a one-click, silent, permanent
action today.

Confidence: high (data-loss-adjacent). A full "Archived" scope + unarchive
write path is a real feature addition (provider write-service work); a
confirmation dialog is a cheap, safe mitigation for the severity in the
meantime (§8, considered but ultimately deprioritized in favor of the items
below — see §9).

### 1.4 `Favorite` is fully write-only

A user can toggle "Favorite" when creating/editing an item
(`VaultItemEditView.swift:33`), and Vaultwarden already decodes and
round-trips it (`VaultwardenCipherModel.favorite`), but
`VaultItemProjection` — the shared struct that drives the list, search, and
detail view — has no `favorite` field at all. There is no star, no
"Favorites" pseudo-group, and no way to see which items are favorited without
opening Edit on each one. The data has existed in the wire model since before
this review; it was simply never threaded through to a single read surface.

Confidence: high. Not on the sibling review's implementation list (mentioned
in its "missing features" list but not its 7-item plan) and not touched by
any open PR — a clean, differentiated, well-contained fix (§8.E).

### 1.5 Vaultwarden collections are never decoded, silently narrowing the documented read scope

`VaultwardenSyncResponse` (`VaultwardenSyncModels.swift`) decodes `profile`,
`folders`, and `ciphers` — never `collections`. Only the opaque
`collectionIds` array on a cipher is preserved, and only for write
pass-through. `PLAN.md`'s scope table lists *"Folders, favorites,
collections, and effective permissions"* as included in the read-only
preview. An organization item filed only under a collection (no personal
folder) gets an empty `groupingLabels`, so it is invisible to the sidebar's
grouping and to any collection-based search. Confidence: high. Not
implemented here — this is provider-layer decode+decrypt work with a larger
blast radius than this review's other picks; flagged for the backlog.

### 1.6 CLI-provider offline snapshot cache is built but never read as a fallback

`ProtonAccountService.cachedSnapshot()` and
`OnePasswordAccountService.cachedSnapshot(accountUUID:)` exist, are
maintained by every successful refresh, and are never called anywhere else in
the app (confirmed by grep). `AppModel.openProton`/`openOnePassword` call
only `refresh()`; on any failure — CLI briefly unavailable, one slow vault,
the 1Password app not yet authorizing — the vault goes straight to a hard
`.failed` state with **no data shown**, even though a valid encrypted
snapshot from the last successful refresh sits on disk. This directly
contradicts the README ("seals a lossy snapshot... for offline read") and
`PLAN.md`'s offline-use section, and is inconsistent with Vaultwarden's own
`unlock()`, which always reads the local cache first. PR #35 makes the
*cache* more honest about partial data (good, complementary), but nothing
wires the cache into the UI as a fallback — that gap is unaffected by #35 and
still open.

**Fix implemented (§8.B):** on an open failure, `AppModel` now falls back to
the provider's `cachedSnapshot()` when one exists, showing the last-known-good
data with a distinct "offline" framing rather than a hard error, matching
Vaultwarden's existing resilience. Confidence: high. Not covered by any open
PR — genuinely complementary to #35.

### 1.7 Steam TOTP seeds are unsupported

`VaultwardenTOTP.parse(seed:)` only recognizes `otpauth://` URIs and bare
Base32; Bitwarden/Vaultwarden's `steam://` TOTP prefix (Steam Guard codes, a
real, shipped Bitwarden feature) is not handled at all. An item with a Steam
TOTP seed shows "Unreadable one-time code seed" forever. Confidence: medium
(niche, but a real and cheaply fixable gap — implemented in §8.D).

### 1.8 Smaller bugs

- **`unlock(_:password:)` is missing the "already open" guard
  `unlockWithBiometrics()` has** (`AppModel.swift:309-315` vs `:511-514`) — an
  asymmetry in the state machine; a stray double-submit could restart an
  unlock flow against an already-open vault. Confidence: medium.
- **Vault count silently capped at 50 for Proton/1Password**
  (`ProtonAccountService.maximumVaults`, `OnePasswordAccountService.maximumVaults`)
  with no error, count, or "and N more" surfaced anywhere — an account with
  51+ vaults silently loses the tail with no diagnostic. Confidence: medium,
  edge case.
- **1Password/Card/Identity/SecureNote items can be viewed but never
  created or edited** — `VaultItemEditView` only models login fields. May be
  an intentional staged limitation (not stated plainly in `README.md`); flagged
  for awareness rather than as a defect.
- **AutoLockController spawns a new unstructured `Task` per input event**,
  including `.scrollWheel`/`.mouseMoved`, just to write one `Date` — pure
  scheduling churn on a hot path. `[touched by #36 — deferring to avoid
  conflict, see §9]`.

---

## 2. Performance problems

### 2.1 Double full-vault decrypt on unlock, synchronously on the Main Actor
See §1.1. This is the headline performance finding of this review.

### 2.2 No revision-gated sync
Same root cause as §1.1/§2.1: every `syncNow` (manual button, post-write,
post-unlock) always re-decrypts and re-sorts every cipher, even when the
server reports nothing changed. The fix in §8.A addresses both.

### 2.3 `AppModel.items` and `VaultSlot.groups` recompute on every access
`AppModel.swift:139-149` re-flatMaps and re-sorts (with a *localized*
comparison — the expensive kind) on every read, including every keystroke in
search and every unrelated `@Published` mutation (`isWriting`,
`biometricError`, mid-hydration content updates). `VaultSlot.groups`
(`VaultSlot.swift:127-150`) rebuilds two dictionaries from scratch on every
access and is called at least twice per sidebar redraw. Both are real,
`O(n)`-or-worse-per-render costs with no memoization. Confidence: medium
(scales with vault size and render frequency, neither measurable here). Not
implemented in this pass — a correct fix needs either `didSet`-based
memoization or moving the computation to the point of assignment, which
touches enough surface area (both files, several call sites) that it's safer
left to a change that can be compiler-checked; flagged for the backlog.

### 2.4 Duplicated, unmemoized, undebounced substring search
`[covered by #40 — "Unify browser and quick search with bounded in-memory
indexing"]`.

### 2.5 No concurrency limiter on favicon fetch bursts
`SiteIconStore.load` has a per-host dedup and a 500-icon cache cap, but no
cap on simultaneous in-flight `URLSession` requests — fast scrolling through a
vault with many distinct hosts can burst dozens of concurrent fetches.
Confidence: medium, minor. Not implemented — small enough to be low priority
relative to the items above.

### 2.6 CLI providers re-probe the CLI's version on every single item open
`ProtonAccountService.content`/`OnePasswordAccountService.content` both call
`runner.probeVersion()` again before every on-demand secret fetch, doubling
the process-spawn count per item open. Confidence: low-medium, cheap
individually.

---

## 3. Missing features

Checked against `ARCHITECTURE.md`'s "Initial non-goals" and `PLAN.md`'s scope
tables before listing anything below; explicitly-deferred items (full parity,
offline mutation, org admin/SSO/Send, autofill/passkeys/extension,
import/export) are not repeated here.

- **Favorites surfaced on read** — §1.4, implemented (§8.E).
- **An Archived items view / restore path** — §1.3. Not implemented this
  pass (bigger, provider-write-shaped feature); a confirmation dialog before
  archiving is a cheap interim mitigation worth a follow-up PR.
- **Collections read support** — §1.5. Not implemented this pass.
- **Password generator** `[covered by #42]`.
- **Configurable auto-lock** `[covered by #36]`.
- **No sort options beyond alphabetical** — real gap, not implemented (small
  but touches the same `AppModel.items`/`VaultBrowserView` surface as several
  in-flight PRs; deferred to avoid pile-up).
- **No right-click context menu on item rows** for common actions
  (copy username/password, reveal, archive) — real gap, high value, but
  `VaultBrowserView.swift` already has three concurrent PRs touching it
  (#32, #38, #40); deferred rather than adding a fourth simultaneous editor of
  the same file.
- **Steam TOTP** — §1.7, implemented (§8.D).
- **CLI-provider offline fallback** — §1.6, implemented (§8.B).

---

## 4. Visual and layout issues

- **1Password account list has no scroll container** inside a fixed
  `.frame(width: 420)` sheet with no height cap (`AddAccountView.swift:284-323`)
  — a user with several 1Password accounts configured will see the sheet grow
  taller than the screen with no way to reach the bottom "Open" buttons.
  Confidence: medium.
- **Settings window is a fixed 540×340** with mixed layout idioms (`Form` on
  General, hand-rolled `VStack` on Privacy, different padding) — tight once
  `biometricError` renders a multi-line red string, and inconsistent rhythm
  between tabs. Confidence: medium.
- **Fixed 120pt label columns** in the KDF-change and origin-approval panels
  (`AddAccountView.swift:407-427`) risk clipping under larger Dynamic Type
  sizes. Confidence: low-medium.
- **Copy/reveal buttons have `.help()` tooltips but no `.accessibilityLabel`**
  distinguishing "Copy password" from "Copy username" — VoiceOver likely
  announces every copy button identically. Confidence: medium.
- **Hue-derived monogram colors have no contrast or colorblind fallback** —
  purely hash-derived hue with no WCAG check and no non-color differentiator.
  Confidence: low-medium.
- **Trailing `Divider()` after the last detail field** leaves a rule hanging
  in the bottom padding (`VaultItemDetailView.swift:21-24`). `[touched by #34
  — likely resolved incidentally; verify after merge rather than duplicating]`.

---

## 5. UX friction

- **No visual feedback on copy** and **no visible countdown for the 30-second
  clipboard clear** `[both covered by #34's "detail copy boundaries" scope —
  verify after merge]`.
- **No "code sent" confirmation or cooldown on the emailed 2FA challenge** —
  `Send Code` disables only while in flight; nothing confirms the email went
  out or prevents spamming it once the request completes. Confidence: medium.
- **1Password's "not authorized" error message names the exact System
  Settings toggle to flip but offers no shortcut to get there.** Confidence:
  low.
- **Declining an origin/KDF approval bounces to the generic sign-in-failed
  screen** rather than framing "you declined X" distinctly. Confidence: low.
- **No loading state while a CLI item's secret fields are fetched** — the
  Password row is simply absent for a beat, then appears with no spinner or
  placeholder `[likely addressed by #41's content-invalidation work or #40's
  scope — verify after merge before re-implementing `isHydrating` wiring]`.

---

## 6. Aesthetic / "high-value macOS app" polish ideas

- No transitions between `AddAccountView`'s internal phases (form → 2FA →
  approval → success) — a subtle cross-fade would make the multi-step flow
  feel considered.
- Primary actions never use `.buttonStyle(.borderedProminent)` — relying on
  `.keyboardShortcut(.defaultAction)` alone gives weaker visual hierarchy than
  a filled button.
- The locked-shell identity rail (`LockedShellView.swift:56-63`) is the one
  piece of real art direction in the app and it's only shown before the first
  account exists; its gradient/typography vocabulary never carries into the
  browser, locked-vault pane, or Quick Search header.
- A TOTP countdown as a small circular progress ring instead of plain "17s"
  text would read faster and add tasteful motion — the single most
  recognizable "well-made app" detail available here for the effort.
- Toolbar sync indicator is purely textual; a rotating `arrow.clockwise` (SF
  Symbol variable animation) during sync would feel more alive than static
  "Syncing…" text.
- CLI status rows (`notInstalled`/`unsupportedVersion`/`notAuthenticated`)
  use plain secondary-colored text for every case; a distinct SF Symbol per
  state (`xmark.circle`, `questionmark.circle`, `clock`) would extend the
  already-solid SF Symbols usage elsewhere.

---

## 7. Novel / delightful / quirky ideas

- **Quick Search direct-copy**: let Quick Search copy the top result's
  password directly (`⌘⏎`) without ever opening the main window — the
  highest-value delight feature for a keyboard-driven daily user, and a
  natural extension of #40's ranking/nav work once merged.
- **A brief unlock micro-interaction**: the locked-shell's `lock.shield`
  animating to `lock.open` right as the browser swaps in would give the
  single most frequent user action a moment of polish.
- **Vault-colored badges in "All Vaults"**: the merged list already tags each
  row with its source vault name in a capsule; pairing that capsule with a
  color derived the same way `ItemIconIdentity.hue` derives site colors would
  make scanning a multi-provider list faster.
- **An "Archived — tucked away, not deleted" framing** once an Archived view
  ships (§1.3/§3): "things you tucked away" reads better than "things you
  deleted," and doubles as the bug fix and a genuinely nice feature.
- **A witty empty state for a freshly created, item-less vault** — the code's
  comments already have an established, opinionated editorial voice; a small
  "Your vault is quiet. Add your first login." would fit it.
- **A one-tap "copy diagnostic details" on CLI failure states** — the
  provider status panes already show a nice `resolvedRealPath → approvedPath`
  arrow when a symlink resolves differently; extending that transparency to a
  copyable diagnostic block would help users file CLI-detection bugs without
  screenshotting text.

---

## 8. What was implemented in this pass

Picked for: real, verified value; small and mechanically safe to write
without a compiler (favor additive fields with defaults, isolated functions,
and localized diffs over broad refactors); and **no overlap** with the eight
PRs already open from the concurrent session (§"Concurrent work"). Each is
its own branch/PR.

| # | Change | Files | Addresses |
|---|--------|-------|-----------|
| A | Skip the redundant full-vault re-decrypt when a Vaultwarden sync's ciphers/folders are unchanged | `AppModel.swift` | §1.1, §2.1, §2.2 |
| B | Fall back to the provider's sealed offline snapshot when a Proton/1Password vault open fails | `AppModel.swift` | §1.6 |
| C | Cancel the in-flight 2FA verification task when the user taps Back | `AddAccountModel.swift` | §1.2 |
| D | Parse `steam://` TOTP seeds | `VaultwardenTOTP.swift` | §1.7 |
| E | Surface `favorite` on the shared projection and show a star badge in the item list | `VaultItemProjection.swift`, `VaultwardenItemDecryptor.swift`, `VaultBrowserView.swift` | §1.4 |

Deliberately **not** attempted here, with reasons:

- Anything needing on-device verification (materials, motion, actual visual
  contrast) — cannot be judged from source alone.
- Full Archived-items view + unarchive write path (§1.3) — real value, but a
  provider-write-service-shaped feature, bigger than this pass's risk budget
  without a compiler.
- Vaultwarden collections decode (§1.5) — same reasoning; touches sync/decrypt
  code with real security-review-adjacent surface.
- `AppModel.items`/`VaultSlot.groups` memoization (§2.3) — real, but the
  correct fix touches enough call sites that it needs compiler verification
  to do safely.
- Anything already covered by an open PR (§"Concurrent work" table), to avoid
  wasted duplicate work and unnecessary merge conflicts.
- Anything that would collide head-on with PR #30's near-total-file-coverage
  security pass.
