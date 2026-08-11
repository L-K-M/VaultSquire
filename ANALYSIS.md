# VaultSquire — living analysis and backlog

This document merges `opus.md` (a point-in-time product/correctness/performance
review) forward into a maintained backlog: items that were acted on in this
pass are marked and moved out of the open lists; everything else is preserved.
Treat `opus.md` as the frozen review this was built from, and this file as
the thing to update next time, not `opus.md` itself.

## Concurrent work

This repository had heavy simultaneous activity from several other agent
sessions while this review and its follow-up PRs were written — independent
reviews and implementation passes under names like `opus/*`, `k3/*`, `glm/*`,
plus a large adversarial security/correctness pass (PR #30) and several other
review/ANALYSIS.md efforts (PRs #33, #48, #66, #69). `gh pr list --repo
L-K-M/VaultSquire --state open` is the live source of truth for what's
actually in flight; this document does not try to enumerate or reconcile all
of it, since that list changes faster than a static doc can track. What it
does do: the items below were checked against that PR list at write time to
avoid proposing something already landed or already open elsewhere, and PRs
this pass depends on or complements are called out inline.

## Implemented in this pass

Each is its own branch/PR, picked specifically to avoid overlapping the
concurrent PRs listed above (password generator, Quick Search keyboard nav,
copy feedback, context menus, CLI content staleness, auto-lock preference UI,
browser/selection reconciliation, and several others were already open
elsewhere and are deliberately not re-done here).

| PR | Change | Status at time of writing |
| --- | --- | --- |
| #47 | `opus.md` — the full review this document is built from | open |
| #49 | perf: skip re-decrypting the vault when a Vaultwarden sync reports no changes (the vault was being fully decrypted **twice**, synchronously, on the Main Actor, on every unlock) | open |
| #53 | fix: fall back to the sealed offline snapshot when a Proton/1Password vault fails to open, instead of a hard dataless error (complements PR #35, which makes the cache itself more honest) | open |
| #63 | fix: cancel the in-flight 2FA verification task when the user taps Back, instead of letting an abandoned request land later | open |
| #67 | feat: support Steam Guard (`steam://`) one-time code seeds | open |
| #70 | feat: surface `favorite` (already collected, never shown) as a star badge in the item list | open |

None of these are merged as of this writing — "implemented" means a PR is
open with the change and (where feasible without a compiler) a test; treat
the PR's own CI result as the actual verification, not this table.

## Review limits

Everything below (and in `opus.md`) is from static source reading on Linux,
with no Swift/Xcode toolchain available — nothing is compile-verified, run,
or visually inspected. `scripts/ci.sh` (the pinned-Xcode macOS lane) is the
real gate for compilation, tests, signing, and visual/accessibility truth.
The codebase has already been through two rounds of adversarial security
review (`docs/security-review/2026-08-11-adversarial-review.md`, PR #30), so
this analysis stays off crypto/Keychain/auth-boundary ground by design.

---

## Open bugs

### Archived Vaultwarden items become permanently unreachable

The toolbar "Archive" action works, but there is no `unarchive`/`restore`
function anywhere and no "Archived" scope/filter in the sidebar — once
archived, an item is gone from the app permanently (recoverable only through
the official Bitwarden web vault). `PLAN.md`'s scope table explicitly
requires *"offer an explicit Archived filter"*; only the exclusion half
exists. The toolbar button also has no confirmation dialog today, making this
a one-click, silent, permanent action.
(`VaultwardenAccountService.swift`, `VaultwardenItemDecryptor.swift:106`,
`VaultBrowserView.swift:515-521`). Confidence: high (data-loss-adjacent). Not
attempted this pass — a full Archived view + unarchive write path is a real
provider-write-shaped feature, bigger than a single well-contained PR; a
confirmation dialog before archiving would be a cheap interim mitigation if
one isn't already covered by a concurrent PR (check `feature/archive-confirmation`
and `k3/archive-confirmation` before adding a third).

### Vaultwarden collections are never decoded

`VaultwardenSyncResponse` decodes `profile`, `folders`, and `ciphers` — never
`collections`. Only the opaque `collectionIds` array on a cipher is preserved,
and only for write pass-through. `PLAN.md`'s scope table lists *"folders,
favorites, collections, and effective permissions"* as included in the
read-only preview. An organization item filed only under a collection (no
personal folder) gets an empty `groupingLabels`, invisible to the sidebar's
grouping and to collection-based search. Confidence: high. Not attempted —
provider-layer decode+decrypt work with a larger blast radius than a single
low-risk PR; needs its own change.

### Smaller open bugs

- **`unlock(_:password:)` is missing the "already open" guard
  `unlockWithBiometrics()` has** (`AppModel.swift:309-315` vs `:511-514`) — an
  asymmetry in the state machine; a stray double-submit could restart an
  unlock flow against an already-open vault. Confidence: medium.
- **Vault count silently capped at 50 for Proton/1Password**
  (`maximumVaults` in both `ProtonAccountService`/`OnePasswordAccountService`)
  with no error, count, or "and N more" surfaced anywhere. Confidence:
  medium, edge case.
- **Card/Identity/SecureNote items can be viewed but never created or
  edited** — `VaultItemEditView` only models login fields. May be an
  intentional staged limitation (not stated plainly in `README.md`); flagged
  for awareness.
- **AutoLockController spawns a new unstructured `Task` per input event**,
  including `.scrollWheel`/`.mouseMoved`, just to write one `Date`. Real, but
  `AutoLockController.swift` has active concurrent PRs (`feat/autolock-preference`,
  `k3/autolock-settings`, `opus/auto-lock-settings`) — check those first
  before adding a fourth editor of the same file.

## Open performance problems

- **`AppModel.items` and `VaultSlot.groups` recompute on every access** — a
  full flatMap + localized-comparison sort, and a from-scratch double
  dictionary rebuild, respectively, on every read including every keystroke
  in search and every unrelated `@Published` mutation. Real `O(n)`-or-worse
  cost with no memoization. (`AppModel.swift:139-149`,
  `VaultSlot.swift:127-150`). Confidence: medium (scales with vault size and
  render frequency). Not attempted — the correct fix touches enough call
  sites to need compiler verification; also check `opus/list-performance`,
  which may already cover this.
- **No concurrency limiter on favicon fetch bursts** — `SiteIconStore.load`
  dedups per host and caps total cached icons at 500, but has no cap on
  simultaneous in-flight requests; fast scrolling through a vault with many
  distinct hosts can burst dozens of concurrent fetches. Confidence: medium,
  minor.
- **CLI providers re-probe the CLI's version on every single item open** —
  `ProtonAccountService.content`/`OnePasswordAccountService.content` both
  call `runner.probeVersion()` again before every on-demand secret fetch.
  Confidence: low-medium, cheap individually.

## Open missing features

Checked against `ARCHITECTURE.md`'s "Initial non-goals" and `PLAN.md`'s scope
tables; explicitly-deferred items (full parity, offline mutation, org
admin/SSO/Send, autofill/passkeys/extension, import/export) are not repeated
here.

- An Archived items view / restore path (see Bugs above).
- Collections read support (see Bugs above).
- No sort options beyond alphabetical.
- No right-click context menu on item rows for common actions (copy
  username/password, reveal, archive) — check `k3/item-context-menu` before
  adding a second.

## Visual and layout issues

- **1Password account list has no scroll container** inside a fixed
  `.frame(width: 420)` sheet with no height cap
  (`AddAccountView.swift:284-323`) — a user with several 1Password accounts
  configured will see the sheet grow taller than the screen with no way to
  reach the bottom "Open" buttons. Confidence: medium.
- **Settings window is a fixed 540×340** with mixed layout idioms (`Form` on
  General, hand-rolled `VStack` on Privacy, different padding) — tight once
  `biometricError` renders a multi-line red string. Confidence: medium.
- **Fixed 120pt label columns** in the KDF-change and origin-approval panels
  (`AddAccountView.swift:407-427`) risk clipping under larger Dynamic Type
  sizes. Confidence: low-medium.
- **Copy/reveal buttons have `.help()` tooltips but no `.accessibilityLabel`**
  distinguishing "Copy password" from "Copy username" — VoiceOver likely
  announces every copy button identically. Confidence: medium.
- **Hue-derived monogram colors have no contrast or colorblind fallback** —
  purely hash-derived hue with no WCAG check and no non-color differentiator.
  Confidence: low-medium.

## UX friction

- **No "code sent" confirmation or cooldown on the emailed 2FA challenge** —
  `Send Code` disables only while in flight; nothing confirms the email went
  out or prevents spamming it once the request completes. Confidence: medium.
- **1Password's "not authorized" error message names the exact System
  Settings toggle to flip but offers no shortcut to get there.** Confidence:
  low.
- **Declining an origin/KDF approval bounces to the generic sign-in-failed
  screen** rather than framing "you declined X" distinctly. Confidence: low.

## Aesthetic / "high-value macOS app" polish ideas

- No transitions between `AddAccountView`'s internal phases (form → 2FA →
  approval → success) — a subtle cross-fade would make the multi-step flow
  feel considered.
- Primary actions never use `.buttonStyle(.borderedProminent)` — relying on
  `.keyboardShortcut(.defaultAction)` alone gives weaker visual hierarchy.
- The locked-shell identity rail (`LockedShellView.swift:56-63`) is the one
  piece of real art direction in the app and it's only shown before the first
  account exists; its vocabulary never carries into the browser, locked-vault
  pane, or Quick Search header.
- A TOTP countdown as a small circular progress ring instead of plain "17s"
  text would read faster and add tasteful motion (check `glm/totp-progress-ring`
  before duplicating).
- Toolbar sync indicator is purely textual; a rotating `arrow.clockwise` (SF
  Symbol variable animation) during sync would feel more alive.
- CLI status rows (`notInstalled`/`unsupportedVersion`/`notAuthenticated`)
  use plain secondary-colored text for every case; a distinct SF Symbol per
  state would extend the already-solid SF Symbols usage elsewhere.

## Novel / delightful / quirky ideas

- **Quick Search direct-copy**: let Quick Search copy the top result's
  password directly (`⌘⏎`) without ever opening the main window.
- **A brief unlock micro-interaction**: the locked-shell's `lock.shield`
  animating to `lock.open` right as the browser swaps in.
- **Vault-colored badges in "All Vaults"**: pair the existing source-vault
  capsule with a color derived the same way `ItemIconIdentity.hue` derives
  site colors, for faster scanning of a merged list.
- **An "Archived — tucked away, not deleted" framing** once an Archived view
  ships: "things you tucked away" reads better than "things you deleted,"
  and doubles as the bug fix and a genuinely nice feature.
- **A witty empty state for a freshly created, item-less vault** — the
  code's comments already have an established, opinionated editorial voice.
- **A one-tap "copy diagnostic details" on CLI failure states** — the
  provider status panes already show a nice `resolvedRealPath → approvedPath`
  arrow when a symlink resolves differently; extending that transparency to
  a copyable diagnostic block would help users file CLI-detection bugs.

---

For the full original write-up — including the reasoning behind each
implemented fix, the "why this is safe" notes, and the section numbering
referenced by PR descriptions (§1.1, §2.3, etc.) — see `opus.md`.
