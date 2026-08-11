# VaultSquire — product analysis and backlog

What is wrong with the app, what would make it better, and what has already
been done about it. This is the product counterpart to the controlling
documents listed in [`README.md`](README.md): `PLAN.md` owns scope,
`SECURITY_AND_TESTING.md` owns invariants and gates, `ARCHITECTURE.md` owns
boundaries. Nothing here overrides any of them — where a suggestion would touch
a security control, that is called out rather than assumed.

Security has been reviewed adversarially twice
(`docs/security-review/2026-08-11-adversarial-review.md`), so it appears here
only where a control is invisible to the user or where a change to the
interface would weaken one.

## Standing caveat

The application-layer review behind this document was read on Linux, where
there is no Swift toolchain: `scripts/ci.sh` needs the pinned Xcode on Apple
silicon. Nothing below has been observed running. Claims about behaviour come
from the source; claims about appearance and timing are marked where they need
a look on-device.

## Where the product stands

The engineering underneath is good. The provider boundary is real rather than
aspirational, the generation-counter discipline around lock is the right design
and is applied consistently, capability gating is enforced in the use case and
not merely in a disabled control, and the comments explain *why* at a level most
codebases never reach.

What was missing was the last third of a product: the app was architected like a
password manager and presented like a technical demo. The first round of work
below closed the largest of those gaps — the keyboard, the context menu, copy
feedback, the generator, the lock setting. What remains is listed after it.

---

## Done

Each landed as its own pull request against `main`.

| Area | Change | PR |
|---|---|---|
| Correctness | On-demand CLI item content is invalidated on sync, so a rotated password is never shown under a fresh "synced" time; stale write errors cleared; the editor no longer closes on another write's completion | [#41](https://github.com/L-K-M/VaultSquire/pull/41) |
| Interaction | Quick Search driven by the keyboard: arrow navigation with a drawn highlight, relevance ranking, vault attribution, match count, and refresh when a vault locks behind it | [#46](https://github.com/L-K-M/VaultSquire/pull/46) |
| Interaction | Item detail: copy confirmation with the clipboard's own expiry counted down, a draining TOTP ring, bounded reveal, a visible fetch state for CLI items, ⌥⌘C / ⇧⌘C | [#50](https://github.com/L-K-M/VaultSquire/pull/50) |
| Interaction | Item list: row context menus (copy username, password, one-time code; edit; archive), deferred copies for CLI providers, empty and no-match states, ⌘R / ⌘E | [#55](https://github.com/L-K-M/VaultSquire/pull/55) |
| Performance | Cached scoped item list, memoised per-vault container list, coalesced site-icon publishing | [#65](https://github.com/L-K-M/VaultSquire/pull/65) |
| Settings | The inactivity timeout is a control instead of a `defaults write`, and the copy no longer denies that a lock policy exists; Settings sizes to its content | [#68](https://github.com/L-K-M/VaultSquire/pull/68) |
| Features | Password generator with an unbiased source, guaranteed character classes, and a strength meter; password reveal; bordered text editors | [#71](https://github.com/L-K-M/VaultSquire/pull/71) |

None of it is compile-verified. Reviewing these on a Mac with the pinned Xcode
is the first job for whoever picks this up.

---

## Open bugs

### Favourites are collected and thrown away

`VaultItemDraft.favorite` is editable in the sheet, is round-tripped through the
write path, and is read back into the draft
(`VaultwardenAccountService.swift:246`). `VaultwardenItemDecryptor.projection`
does not carry it (`VaultwardenItemDecryptor.swift:117-127`), so
`VaultItemProjection` has no favourite field and nothing in the list, the sort,
or the sidebar reflects it. A user marks a favourite and the app never mentions
it again. Either surface it — a pinned section, a star in the row, a filter — or
stop offering the toggle.

### Unlocking one vault re-opens vaults the user deliberately locked

Every successful Vaultwarden unlock calls `openCredentialFreeVaults()`
(`AppModel.swift:370, 384-388`). The intent is right — one gesture opens the
app. But locking the 1Password vault on purpose and later unlocking Vaultwarden
brings it back. Opening only credential-free vaults that were not explicitly
locked in this session would keep the convenience without overriding a
deliberate act.

### A second submit is dropped in silence

`AppModel.save(_:to:)` opens with `guard !isWriting else { return }`. Pressing
Save twice, or pressing it while an archive is in flight, does nothing at all —
no feedback, no queue. The button is disabled while `isWriting`, so this is
narrow, but the guard should not be the only answer.

### Quick Search still does not see a sync

Locking a vault now refreshes an open panel ([#46](https://github.com/L-K-M/VaultSquire/pull/46)),
but a sync that lands while the panel is up is still invisible to it: the panel
holds the snapshot it was given. `ApplicationCoordinator.refreshQuickSearch()`
exists and needs one more caller on the sync-completion path.

### Smaller

- **`lock(_:)` clears the clipboard for an unrelated vault**
  (`AppModel.swift:472`): copy from vault A, lock vault B, lose A's copy.
  Defensible, undocumented, surprising.
- **Accessibility identifiers embed user data.** `"reveal-\(field.label)"`
  (`VaultItemDetailView.swift`) where the label can be a custom field name, so a
  UI test keyed on it is keyed on vault content.
- **1Password's "Open" is not the default action** while Proton's is
  (`AddAccountView.swift:159` vs `:316`); Return does nothing in that pane.
- **`AutoLockController` counts passive `.mouseMoved` as activity**
  (`AutoLockController.swift:107`). With the app frontmost and the pointer over
  the window, ambient pointer motion defeats the inactivity lock indefinitely.
  Keystrokes, clicks, and scrolls are the honest signals. This is a security
  decision, not just an interaction one.
- **A second Vaultwarden account silently replaces the first.** Credentials are
  keyed to `.primary`; the add-account form offers itself again with no warning
  that it will overwrite.
- **1Password OTP fields** are read from the field's `value`
  (`OnePasswordReadModel.swift:216`) and rendered through
  `VaultwardenTOTP.generate`. If some `op` build returns the generated code
  rather than the `otpauth://` URI there, the row reads "Unreadable one-time
  code seed". Unverified. A fallback that shows a bare 6–8 digit value as a code
  costs nothing and removes the failure mode.

---

## Open performance work

Everything here is per-frame work in an app that will meet vaults of a few
thousand items — an ordinary size, not a pathological one.

### The detail view re-decrypts on every render

`appModel.detail(for: selection)` is called from the view body
(`VaultBrowserView.swift`), and it linearly scans the cipher array and runs an
AES-CBC decrypt plus HMAC verify per field on every invocation. Any `AppModel`
publish re-runs it. Never wrong, just done hundreds of times where once would
do. Memoise on (item id, snapshot generation, hydration state).

### There are now two search implementations

Quick Search ranks ([#46](https://github.com/L-K-M/VaultSquire/pull/46));
the browser's list still uses the original substring `matches`
(`VaultBrowserView.swift`), which builds a haystack array per item per keystroke
and runs `localizedCaseInsensitiveContains` over each. The two should be one
matcher — ideally the ranked one, so the list orders by relevance while
searching and by title otherwise.

### The TOTP timeline regenerates every second

`TimelineView(.periodic(by: 1))` runs a full HMAC once a second when the code
changes once a period. Cheap in absolute terms; the countdown and the code
should be separate views so only the countdown ticks.

---

## Open interaction gaps

- **No drag-and-drop.** Dragging a username or password onto another app is a
  standard macOS gesture and one of the few ways to fill a field without a
  browser extension. It would go through `ClipboardService` so the expiry
  survives.
- **No recently used or recently viewed**, anywhere — which is also the right
  answer for Quick Search's empty query, where it currently lists every item
  alphabetically in a 330-point panel.
- **No sort control** (title only), no category filter, no favourites filter.
- **No multi-select and no bulk action.**
- **Return and Space do nothing in the item list.**
- **No ⌘F**, no shortcut for the one-time code, no shortcut to open a website.
  (Focusing a `.searchable` field programmatically needs `searchFocused`, which
  is macOS 15; on 14 it needs a different search field.)
- **The last-selected scope is not restored.** Window restoration is
  deliberately off for secret-bearing state, but the *scope* is not secret and
  reopening on "All Vaults" every time is a small tax on every launch.

---

## Open visual and layout work

### The toolbar status item fights the toolbar

A bare relative timestamp ("2 min ago") in the navigation slot with no label,
wrapped in `fixedSize` and manual padding whose own comment explains it is
compensating for the toolbar's background capsule. With a leading symbol and the
word "Synced" it would read as intended and stop needing the padding.

### The edit sheet is pinned to 460 × 560

Settings now sizes to its content ([#68](https://github.com/L-K-M/VaultSquire/pull/68));
the sheet does not. Same failure at increased text sizes.

### Density and truncation in the item row

The vault badge shares a line with the subtitle and wins the space contest on a
narrow window, truncating the username — the more useful of the two. There is
also no density option; a password manager list benefits from a compact mode.

### The sidebar summary reads as a fragment

`"\(count) items in \(open) open"` → "142 items in 2 open". "142 items · 2
vaults open" says the same thing and parses.

### There is no offline or cached indication

All three providers fall back to a sealed local snapshot and the UI never says
so. A "showing the last synced copy" badge is both honest and reassuring, and it
is the natural home for the sync error string that currently lives as a
truncated toolbar label.

### The locked-vault pane is a left-aligned wall

A title, a subtitle, a 320-point field, and buttons in the top-left of a wide
pane, with the rest empty. Centred in a card with the provider's mark it would
read as a designed state rather than an unfinished one.

### The one piece of art direction is shown once

The empty shell's identity rail — gradient, tracked small caps, shield — is the
only art direction in the app, and it appears only before the first account
exists. Its vocabulary should carry into the locked pane, the empty detail, and
the Quick Search header.

*To check on-device:* the rail sets `.foregroundStyle(.white)` on the container
and `.secondary` on two descendants. Modern SwiftUI derives hierarchical styles
from the set foreground style, in which case this is correct white-at-reduced-
opacity; if it instead resolves against the colour scheme, the tagline is
near-black on dark navy in Light Mode.

---

## Missing features, roughly by value

1. **Favourites** — the data is already collected and discarded. See above.
2. **Vault health**: reused, weak, and short passwords, and logins with no
   one-time code. Entirely local, works across all three providers, and is the
   kind of feature that justifies a native client over a browser extension. The
   strength estimator from [#71](https://github.com/L-K-M/VaultSquire/pull/71)
   is the piece this needs.
3. **Recently used / recently viewed**, feeding both the list and Quick Search.
4. **Delete and trash for Vaultwarden**, which offers archive only.
5. **Password history** — Vaultwarden preserves it in the cipher and the write
   path is careful to keep it; nothing displays it.
6. **Item types beyond login for create and edit** — secure notes at minimum.
7. **Folder management** (create, rename, move an item); folders are read-only.
8. **A menu bar extra**: search, copy a one-time code, lock — without raising
   the window.
9. **Export** of non-secret metadata for auditing, or an explicit "no export by
   design" statement in Settings so the absence reads as a decision.
10. **Per-item reprompt** — Vaultwarden's `reprompt` flag is preserved on write
    and ignored on read.

---

## Making it look like an app worth paying for

In rough order of effect per hour:

- **A real selection-empty state.** The detail placeholder is
  `ContentUnavailableView` with an item count as its *description*, which is
  where a count should never live. Replace it with the app's mark, the scope
  name, and the two or three actions that make sense there.
- **One accent per provider.** Vaultwarden, Proton, and 1Password each get a
  tint for their sidebar icon and locked pane. Merged lists become readable at a
  glance, and it costs one dictionary.
- **Monospaced, grouped secrets.** Passwords already render monospaced; group
  them in four-character runs with subtle colouring for digits and symbols,
  which is how people actually read a password aloud.
- **Materials, not flat panes.** The Quick Search panel uses `.regularMaterial`
  and looks the part; the sidebar should use `.sidebar` list style with a
  material background, and the detail should sit on a subtly elevated surface.
- **Typography discipline.** The app mixes `.largeTitle`, `.title2`,
  `.system(size: 34)`, and `.system(.title3, design: .rounded)` across four
  screens. Pick one scale — rounded for display, default for content — and use
  it everywhere.
- **Motion.** There is one animation in the app (the sidebar twisty). A vault
  opening, an item's fields appearing, and the lock closing all deserve a short,
  snappy transition. The lock is the emotional beat of a password manager and it
  currently happens instantly and invisibly.
- **A proper locked treatment.** When everything locks with the window open,
  blur the content behind a material and put the unlock affordance on top,
  rather than swapping to a different layout.

---

## Ideas worth stealing from

Not a backlog — a list of things that would make this app memorable rather than
merely correct.

- **The Squire.** The app has a name and a heraldic shield and does nothing with
  either. A small mark that latches shut on lock — one 200 ms animation — would
  give it a signature moment. Quiet, not cute.
- **Clipboard countdown in the menu bar.** While a copied secret is live, a tiny
  draining ring; click to clear immediately. It makes the app's best-hidden
  security property its most visible one.
- **Screenshot shyness.** While a secret is revealed, set the window's
  `sharingType` to `.none` so screen recordings and screenshots capture a blank
  pane. One line, and the kind of thing users tell each other about.
- **Type-to-find in the item list.** Focus the list, start typing, filter
  immediately — no ⌘F. It is how the Finder behaves and how nothing else in this
  category does.
- **Peek with Space.** Select a row, tap Space, get a floating card with the
  username and a copy button without leaving the list.
- **Hold to reveal.** ⌥-hover any secret to show it only while held, so nothing
  is left on screen at all.
- **Vault weather.** One line in the sidebar footer: "3 reused · 1 weak · synced
  2 min ago". Local, honest, and a reason to open the app when you don't need a
  password.
- **Honest offline mode.** When the network is gone, say so and keep working
  from the sealed snapshot with a dated badge, rather than surfacing a truncated
  error string in the toolbar.
- **Provider parity table in Settings.** A small grid of which actions each
  connected provider supports, and why the others are absent. The capability
  model already knows the answer; showing it turns a limitation into an act of
  transparency.
