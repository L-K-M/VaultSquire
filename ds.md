# VaultSquire — Deep Review (ds.md)

- Review date: 2026-08-11
- Reviewer: independent pass over the full source tree on `chosen-dragon` at `0c05294`
- Review environment: Linux checkout; **no** macOS runtime, Xcode build, XCTest run,
  UI test, Instruments, VoiceOver, signing, or pixel inspection was possible. Every
  claim below is from static reading unless it says otherwise.
- Scope: `VaultSquire/` app sources, tests, UI tests, project configuration, and the
  governing documents as needed for context.
- Companion document: `ANALYSIS.md` (the merged, forward-looking analysis derived from
  this review). This file is the full finding record.

## How to read this document

Findings are grouped by severity and tagged so they can be tracked:

- **B** — bug or behavior that is wrong today (verifiable by reading).
- **P** — performance or responsiveness risk.
- **F** — missing capability or feature gap.
- **V** — visual, layout, or interaction problem.
- **U** — usability / user-friendliness gap.
- **S** — security-posture note (not necessarily exploitable, usually a gap between
  posture and implementation).
- **I** — novel, delightful, or differentiating idea (product idea, not a defect).

Each entry that this pass implemented has a `PR:` line naming the branch. Entries
that are already covered by another open PR name it. Everything else is a candidate
for future work and is carried into `ANALYSIS.md`.

---

## Executive assessment

This is a serious, unusually well-disciplined codebase for an early password-manager
client. The security architecture (fail-closed version gates, no-shell bounded CLI
executor with an environment allowlist, session generations, clipboard ownership
checking, AEAD-sealed caches, origin approval, capability gating, adversarial-review
history) is genuinely strong, and the test suite is broad (~465 unit tests) with real
fuzz and leakage suites. The code is consistently commented, and the comments often
document *why* as well as *what*.

The gaps are where the product surface meets the product promise:

1. Several small but real UI correctness bugs — most importantly the Quick Search
   hand-off, which can silently fail to show the chosen item (B1/B2), and a closed
   main window that cannot be reopened (B3).
2. The keyboard-first story is incomplete: Quick Search has no arrow-key navigation,
   no selected-row styling, and no per-vault source badge; revealed secrets are
   selectable so `⌘C` bypasses the clipboard-expiry control entirely (S1).
3. A password manager without a password generator in its create/edit sheet (F1),
   no way to remove an account from the UI (F4), no archive confirmation or undo
   (B5), and an auto-lock policy that is active but invisible and not adjustable
   (F2).
4. Performance architecture that will not meet the documented 100k-item budgets
   (P1–P5): synchronous substring search on the main actor, whole-list rebuilds and
   sorts on every render, unbounded Quick Search rendering for an empty query, and a
   groups dictionary rebuilt per render.
5. The UI is coherent and clean but deliberately spartan; the browser is nearly all
   default AppKit/SwiftUI chrome while the empty shell is branded. The two halves
   feel like different apps (V1).

Nothing below authorizes release; the existing workstream and security gates remain
controlling. Several findings intentionally overlap with the earlier
`ANALYSIS.md`/adversarial review; this pass re-verified them and adds its own.

---

## B — Bugs

### B1. Quick Search hand-off can leave the browser showing the wrong thing (fixed)

`VaultBrowserView` consumes `appModel.quickSearchSelection` with:

```swift
if case .vault(let account) = appModel.scope, account != newValue.account {
    appModel.scope = .allVaults
}
selection = newValue
```

Two problems:

- **Group scopes are missed.** When the browser is scoped to a *group* (a Proton
  share or Vaultwarden folder) belonging to account A and the picked item belongs to
  account B, the `if case .vault` pattern does not match, the scope is not widened,
  and the item list keeps showing account A's group while the detail pane shows
  account B's item — a detail for an item not in the list.
- **Scope-change clearing races the hand-off.** When the scope *is* widened, the
  separate `.onChange(of: appModel.scope) { selection = nil }` fires after
  `selection = newValue`, so the freshly handed-off selection is wiped and the detail
  pane shows the empty state. Net effect: Quick Search from a different-account scope
  appears to do nothing.

`PR: fix/browser-selection-correctness`.

### B2. Selection is never reconciled with the filtered list (fixed)

Changing the search query or a sync removing an item does not clear or adjust
`selection`. The detail pane keeps showing an item that is no longer visible in the
list (it may not even match the query). Scope changes clear the selection, but query
changes and post-sync removals do not. (The earlier review noted this; this pass
verified it and implemented the fix.)

`PR: fix/browser-selection-correctness`.

### B3. Closing the main window leaves no way to reopen it (fixed)

`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`, so the
app keeps running, but:

- the main scene is a `Window`, not a `WindowGroup`, and nothing in the app
  recreates the window;
- `applicationShouldHandleReopen` is not implemented, so a Dock click does nothing
  when no window exists;
- the only command that could be useful (Quick Search, `⌘⇧Space`) lives in the
  Window scene's `.commands`, and its panel is not the browser.

A user who closes the window is left with a running app that only Quit can end. The
fix is a `WindowGroup` with the same sizing, so Dock-click reopen works, plus an
explicit `applicationShouldHandleReopen` fallback for robustness.

`PR: fix/reopen-main-window`.

### B4. Partial CLI refreshes silently replace a complete offline snapshot (fixed)

`ProtonAccountService.refresh()` and `OnePasswordAccountService.refresh()` loop over
vaults and `continue` past a vault whose listing fails, then seal the *partial*
result into the device cache. A transient failure on one vault therefore quietly
turns the last-known-good offline snapshot into a smaller one — the offline copy no
longer has the vaults that failed, with no marker that it is incomplete. The fix:
keep listing everything readable for the on-screen session, but refuse to seal a
partial capture (preserving the last complete offline snapshot) and surface a note on
the vault row.

`PR: fix/preserve-complete-cli-snapshots`.

### B5. Archive is destructive-adjacent with no confirmation and no undo (fixed)

The toolbar Archive button immediately archives the selected item; the item vanishes
from the list; and this build has no unarchive surface at all (the capability is
deliberately not implemented). One mis-click and the item is unreachable inside
VaultSquire (it still exists server-side). A confirmation dialog before archiving is
the minimum mitigation.

`PR: feature/archive-confirmation`.

### B6. Auto-lock is active but invisible and mis-documented

`AutoLockController` is started from the root scene and locks after the default
15 minutes of inactivity, yet Settings shows no control and the caption claims a
configurable lock policy "is enabled only after their interaction and security tests
pass" — which is already false: the inactivity lock is live today. The default also
differs from the 5-minute figure PLAN.md recommends pending UX work. Either expose
the control or state the fixed behavior; hiding an active security policy from the
user is worse than either.

`PR: feature/auto-lock-timeout` (control); the caption truthfulness is also touched
by the open PR `fix/honest-settings-copy`.

### B7. Quick Search can keep a stale item snapshot

`QuickSearchPanelModel` copies the item list at presentation time and never refreshes
it. Because the panel is floating and `hidesOnDeactivate = false`, it can stay open
while a sync replaces items, while another vault locks (its rows still advertise that
vault's items), or while an item is created/edited. Locking the *last* vault dismisses
the panel, but locking one of several does not. Dismiss or live-update on session
generation changes.

### B8. Per-vault lock keeps the locked vault's site icons in memory

The row lock button calls `appModel.lock(account)` but not `siteIcons.clear()`; only
Lock All and the automatic lock clear the store. Icons derived solely from the
locked vault can therefore remain on screen and in memory in a multi-vault session.
Already covered by the open PR `fix/clear-icons-on-vault-lock`; verified independently.

### B9. `VaultSession` is dead code

The `VaultSession` actor and `SessionState` machine (Workstream 2's session contract)
are referenced only by their own tests. `AppModel` implements the same concerns
(generations, cancellation registry, lock semantics) with `VaultSlot`. Two parallel
state models that disagree by construction is how subtle regressions arrive; either
wire `VaultSession` in or delete it and its tests. (The earlier review did not call
this out; it is a maintainability finding, not a runtime bug.)

### B10. TOTP copy button copies the *generated code* (good) but the detail row's
countdown can briefly show a stale code

`TimelineView(.periodic(by: 1))` regenerates at each tick, so the code and countdown
stay in sync; this is fine. Minor: `Int(...rounded(.up))` shows "30s" for a freshly
rolled-over window, which reads correctly. Not a bug — noted as verified behavior.

### B11. Proton/1Password empty-vault groups never appear in the sidebar

`VaultSlot.groups` seeds Vaultwarden folders from `folderNames` (so empty folders
show), but Proton shares and 1Password vaults are derived only from items, so an
empty vault has no sidebar row at all. Minor, but it makes "did my vault disappear?"
possible when a vault empties. Seed from the snapshots' vault lists as well.

### B12. `Add Account` success copy instructs the user to unlock with the master
password even for CLI providers

The success view text is fixed ("unlock your vault with your master password") and
shows after a Proton/1Password flow too, where there is no master password. Wording
should depend on the provider that was just added.

---

## S — Security-posture notes

### S1. Revealed secrets are selectable text, so ⌘C bypasses the clipboard expiry

`VaultItemDetailView.secretRow` applies `.textSelection(.enabled)` to the revealed
secret. The whole clipboard contract (30-second expiry, clear-on-lock, ownership
check) lives in `ClipboardService`; any selection-based copy bypasses it and leaves
the secret on the pasteboard indefinitely. The copy button is the sanctioned path.
Fix: remove text selection from secret values (keep it for plain fields, which are
non-secret). Implemented with the copy-confirmation work.

`PR: feature/copy-confirmation`.

### S2. Master-password reprompt items reveal and copy without re-verification

The wire model preserves `requiresReprompt` and the decryptor emits the secret
fields, but the detail view reveals/copies them with no fresh authentication. The
comment in `VaultwardenCipherModel` acknowledges this ("until re-verification
ships"). This matches the earlier review's finding; it remains unimplemented and
should be a stop-ship item before release. Not implemented here (needs a real
authentication flow and negative tests).

### S3. CLI executable identity is path + self-reported version only

A replaced binary at an allowlisted path can print an admitted version. The earlier
review's recommendation (code-signature/team/designated-requirement assessment,
persisted identity, replacement detection) stands. Not implemented here.

### S4. CLI cache keys are not user-presence-bound

Proton/1Password cache-envelope keys are plain device-only Keychain items; the
architecture wants a user-presence-bound release. Not implemented here.

### S5. Site-icon fetching tells the site about the vault — but the toggle copy is
good

The opt-in privacy switch and per-origin fetch design are exemplary. One nit: the
"letter on a colour" fallback is presented as the privacy story, which is accurate.
No change.

### S6. `Home`-directory discovery uses the real user home for candidate paths

`ProtonCLILocator` reads `FileManager.default.homeDirectoryForCurrentUser` for
candidate paths. Discovery only; execution uses the allowlisted absolute path. Fine.

---

## P — Performance and responsiveness

### P1. Search is synchronous substring scanning on the main actor (documented)

Both browser search (`VaultBrowserView.matches`) and Quick Search
(`QuickSearchPanelModel.matches`) linearly scan arrays with
`localizedCaseInsensitiveContains` per item per keystroke, on the main actor. This
cannot meet the documented 100,000-item / 250 ms budgets. A normalized, bounded
in-memory index built off-main with debounced publication is the right shape; the
empty `perf/scalable-search` branch is where it belongs. Not implemented here.

### P2. `AppModel.items` flattens and sorts every open vault on every access

`AppModel.items` and `allOpenItems` recompute `flatMap` + sort each time SwiftUI
evaluates them, and view properties call them multiple times per render. Cache by
scope/session generation. Documented; not implemented.

### P3. Quick Search renders the entire corpus for an empty query (fixed)

Opening Quick Search with no query builds a `List` over every open item. Cap the
rendered result set (and let typing narrow it). Implemented with a 100-row cap.

`PR: feature/quick-search-polish`.

### P4. `VaultSlot.groups` rebuilds from every item on every render

The groups dictionary is derived in the sidebar on each body evaluation (disclosure
visibility, group rows, title lookup all call it). Cache when projections publish.
Documented; not implemented.

### P5. Icon fetching can burst

Enabling icons in a large vault can fire many concurrent fetches and main-actor
decodes; the store dedupes hosts and caps the cache, but there is no concurrency
limit and rows leaving the viewport do not cancel. A small semaphore and MIME/size
checks are cheap wins. Documented; not implemented.

### P6. Icon bytes are accumulated one byte at a time

`SiteIconFetcher.fetch` appends `byte` in a loop over `AsyncBytes` for up to 256 KiB.
Consume chunks (`for try await chunk in bytes` doesn't exist on AsyncBytes, but
`bytes.lines` or a bounded buffered read does; at minimum read into a buffer). Low
impact; documented.

### P7. PBKDF2 unlock runs off-main (good) but blocks a cooperative thread

`deriveMasterKey` is `async` and off-main, so the UI does not freeze, but a 600k-iteration
derivation occupies one cooperative pool thread for its duration. Acceptable; note
for the future.

---

## F — Missing features

### F1. No password generator (implemented)

The create/edit sheet asks the user to invent or paste a password. Implemented an
offline generator (character-set mode with length and set toggles, ambiguous
character exclusion) with a dice button and options popover in the edit sheet, plus
unit tests. No word-list/passphrase mode yet (word-list content provenance needs its
own review).

`PR: feature/password-generator`.

### F2. No auto-lock control in Settings (implemented)

Added an inactivity timeout picker (5/10/15/30/60 minutes, or "never — system events
still lock") bound to the key `AutoLockController` already reads. See B6.

`PR: feature/auto-lock-timeout`.

### F3. No account removal / logout in the UI

`AccountDescriptorStore.remove` exists and nothing calls it. There is Add Account and
Lock, but no way to remove an account, clear its sealed cache and credentials, or
reconnect after a wrong URL. The locked-shell copy ("add the account again to rebuild
it") papers over the absence. Needs a Settings/Accounts pane with explicit
cache/credential deletion semantics and confirmation. Documented.

### F4. No unarchive / trash / restore

Archive is implemented (Vaultwarden) with no way back; the earlier review's finding
stands. Requires the dedicated capability and tests.

### F5. No favorites surface

The edit sheet has a Favorite toggle (Vaultwarden), but the projection drops it and
browse/search has no Favorites scope, star, or ranking. Either surface it or remove
the toggle. Documented.

### F6. Only logins are editable

Cards, identities, notes, SSH keys have no create/edit path, and the Add button says
"Add Item" but only creates logins. Label the button "Add Login" until type-specific
drafts exist. Documented.

### F7. No copy-from-row and no keyboard copy for the selected item

Copying a password requires select-then-copy in the detail pane. A `⌘C` on a
selected row (copying its password through the expiry path) and a row context menu
would make the keyboard-first claim real. Documented.

### F8. No duplicate/weak-password detection, no health view

A local-only reuse/weakness audit would be high value; breach APIs need a separate
privacy review. Documented.

### F9. No folder picker on create/edit

New items are always created with no folder (`folderID` is nil for creates), and
edits cannot move an item between folders even though the write path preserves the
folder. A folder picker in the edit sheet is a natural small feature. Documented.

### F10. No custom-field editing

Custom fields are preserved verbatim on edit but cannot be added, removed, or
changed. Documented.

### F11. No import/export, attachments, passkeys, autofill, menu-bar extra

All correctly deferred by the plan; the README should say so explicitly (the open
`security-review-password-manager` PR improves this). Documented.

---

## V — Visual and layout issues

### V1. Two visual personalities

The empty shell is a branded dark-gradient rail with rounded typography; the browser
is stock `NavigationSplitView` + `List` + toolbar. Carrying a restrained visual
system (materials, accent, icon treatment, empty states, status language) through
the unlocked app would make it feel like one product. Documented; needs a real
visual pass on macOS.

### V2. Default window is cramped for three columns

`820×560` with a ~230 pt sidebar leaves a squeezed list and detail. Raise the
default, give the columns sensible minimums, and verify narrow-window collapse.
Documented.

### V3. Detail fields are a flat label/value/divider list

Cards, identities, notes, and custom fields would read far better grouped into
sections with consistent action alignment, and pinned actions where long notes would
push them away. Documented.

### V4. Toolbar is five equal icons with weak context

Add/Edit/Archive/Sync/Lock All are all equally weighted; Archive is a one-click
destructive-adjacent action with no confirmation (B5). Move secondary actions to
context menus or an overflow; keep Add and Sync prominent; show shortcuts in menus.
Documented; confirmation part implemented.

### V5. Errors are embedded in sidebar subtitles

A long CLI/network error replaces the account subtitle in a single truncated line.
A status badge with a detail/retry popover would be far better. Documented.

### V6. Small click targets

The custom 12×12 disclosure control and the borderless row lock button are likely
below comfortable pointer and accessibility minimums. Expand hit regions while
preserving alignment. Documented.

### V7. No copy feedback anywhere

Copy buttons are unlabeled icons with only a tooltip; the user gets no "copied"
confirmation and no indication of the 30-second expiry. Implemented a transient
"Copied" state on detail copy buttons.

`PR: feature/copy-confirmation`.

### V8. The site-icon privacy block dominates the Privacy tab

Admirable honesty, verbose layout. Lead with one crisp sentence and a "Learn More".
Documented.

---

## U — Usability

### U1. Quick Search lacks keyboard result navigation and selection styling

Return always opens the first result; there is no arrow-key navigation, no selected
row, no `⌘1/2/3` copy actions, and no match highlighting. This is the centerpiece of
the keyboard-first promise. Arrow-key handling is implementable with a tracked
selection index + `onKeyPress` (macOS 14+); not implemented here because it cannot be
exercised in this environment and a broken keyboard path is worse than none. The
vault source badge and result cap are implemented.

`PR: feature/quick-search-polish`.

### U2. Quick Search results are not globally sorted

`AppModel.allOpenItems` flat-maps per-vault (already sorted) lists, so a merged
search result is grouped by vault order rather than alphabetically merged. The
browser's All Vaults list sorts; Quick Search does not. Cheap fix (sort in the
model); included in the polish branch.

### U3. No "why is this disabled?" on capability-gated actions

A Proton item next to a Vaultwarden one shows disabled Edit/Archive with no reason.
A short tooltip ("Read-only through the official CLI") would turn capability
differences into trust. Documented.

### U4. The locked-vault pane and unlock flow are fine but there is no "show password"
during entry

The edit sheet's password field has no reveal toggle, so a user generating or typing
a password cannot verify it. Implemented a reveal toggle with the generator.

`PR: feature/password-generator`.

### U5. No copy countdown anywhere in the UI

The clipboard expires in 30 s but nothing tells the user. A subtle countdown next to
the last copied secret would be both delightful and security-informative. Documented
as part of the copy feedback work (basic "Copied" state implemented).

### U6. Empty states are decent but the locked shell copy is misleading

"If the unlock prompt doesn't appear, add the account again to rebuild it" suggests
duplicate account creation. Needs account-scoped diagnostics. Documented.

---

## I — Novel, delightful, quirky ideas

These are product ideas, not implementation authorization. They are collected here
and in `ANALYSIS.md` so future work has a menu.

1. **Squire mode.** A compact keyboard-driven panel where typing narrows and `⌘1`,
   `⌘2`, `⌘3` copy username/password/TOTP without opening the main window, each with
   a non-secret confirmation and the expiry countdown. Natural extension of the
   Quick Search panel.
2. **Vault Constellation.** An optional overview tab showing each open vault as a
   tasteful card (freshness, provider, item count, read/write capability, lock
   state) — no secret-derived content. Makes multi-vault status legible at a glance.
3. **Tiny heraldry.** Extend the deterministic monograms into subtle locally-hashed
   "crests" — more distinctive than a colored letter, still zero network and zero
   leakage.
4. **Polite shoulder-surfing mode.** A one-click presentation mode that hides
   usernames, URLs, titles, and icons until hovered/focused. Never described as
   screen-capture protection.
5. **Secret choreography.** After a copy, animate only the copy icon into a small
   ring representing the 30-second expiry — never the secret itself. Delightful and
   security-informative at once.
6. **Contextual "why disabled?"** explanations on capability-gated actions.
7. **Travel lock.** A deliberately stronger temporary posture: disables Touch ID
   quick unlock and purges provider snapshot keys until the next full
   authentication, with a careful recovery path.
8. **Local security garden.** A calm, entirely local health page where reused/weak
   credentials are small plants needing attention — optional metaphor, plain-language
   accessibility labels.
9. **Password pastiche.** When generating, offer themed passwords (e.g. a
   "sentence" mode made of adjective-noun-verb-number templates from a small local
   list) — a middle ground between random strings and full diceware that needs no
   external word list.
10. **Copy whisper.** When a secret is copied, briefly show the countdown in the
    toolbar's status capsule so the expiry is visible without opening the detail
    pane.

---

## What was implemented in this pass

| Entry | Branch / PR | What changed |
|---|---|---|
| B1, B2 | `fix/browser-selection-correctness` | Quick Search hand-off widens scope for group scopes too; scope-change no longer wipes a handed-off selection; selection reconciled when query or items remove it |
| B3 | `fix/reopen-main-window` | `Window` → `WindowGroup` + `applicationShouldHandleReopen` fallback |
| B4 | `fix/preserve-complete-cli-snapshots` | Proton/1Password refuse to seal partial refreshes; partial note surfaced on the row; tests |
| B5 | `feature/archive-confirmation` | Confirmation dialog before archiving |
| F1, U4 | `feature/password-generator` | Offline generator + dice/popover UI + password reveal toggle + tests |
| F2, B6 | `feature/auto-lock-timeout` | Settings inactivity picker bound to the existing key |
| V7, S1 | `feature/copy-confirmation` | Transient "Copied" state; secrets no longer selectable text |
| P3, U1 (badge), U2 | `feature/quick-search-polish` | Result cap (100), globally sorted merged results, per-vault source badge, tests |

Everything else in this document is carried forward in `ANALYSIS.md` as future work.
