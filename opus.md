# VaultSquire — product and implementation review

A full read of the application layer as it stands on `main` (0c05294): every
file under `VaultSquire/App`, `VaultSquire/Domain`, `VaultSquire/Features`,
`VaultSquire/Infrastructure`, and the three provider verticals, plus the
project file, the test suite's shape, and the three open pull requests.

This document is about the *product*: bugs, responsiveness, interaction,
appearance, and what a person actually gets when they open the app. The
security posture has been reviewed adversarially twice already
(`docs/security-review/2026-08-11-adversarial-review.md`, PR #30), so security
appears here only where a control is invisible to the user or where a UI change
would weaken one.

## Verdict first

The engineering underneath is genuinely good. The provider boundary is real
rather than aspirational, the generation-counter discipline around lock is the
right design and is applied consistently, capability gating is enforced in the
use case and not merely in a disabled button, and the comments explain *why* at
a level most codebases never reach. Nothing here reads as sloppy.

What is missing is the last third of a product. The app is architected like a
password manager and presented like a technical demo: there is no password
generator, no favourites, no context menu, no copy feedback, no configurable
auto-lock, no keyboard path through Quick Search, and the item list has no
empty state. A user's second minute with the app is mostly discovering that the
obvious gesture does nothing. That is the gap worth closing, and almost all of
it is cheap.

Two ordinary correctness bugs are worth fixing regardless of polish: on-demand
CLI item content is never invalidated (§1.1) and a stale write error surfaces on
an unrelated item (§1.3).

### Method and limits

Read on Linux. There is no Swift toolchain in this environment, so nothing here
is compile-verified or run; `scripts/ci.sh` needs the pinned Xcode on Apple
silicon. Every claim below is from source reading, and anything I could not
settle from the source is marked as such rather than asserted.

---

## 1. Bugs

### 1.1 On-demand CLI content is never invalidated — stale secrets after a sync

`AppModel.hydrateIfNeeded` fetches a Proton or 1Password item's secret fields
once and caches them in `protonContent` / `onePasswordContent`
(`AppModel.swift:655-698`). Both maps are cleared on lock and on account
close, and nowhere else. `syncNow(_:)` replaces the snapshot and the
projections for a CLI vault (`AppModel.swift:844-879`) but leaves the fetched
content untouched.

So: open an item, read its password, change that password in 1Password, press
Sync, reopen the item — VaultSquire shows the old password, with a fresh "last
synced" timestamp beside it, until the vault is locked. For a password manager
that is the worst possible failure mode of a caching bug, because the value
shown is confidently wrong rather than absent.

Fix: drop that account's entries from both maps on a successful refresh. The
next open re-hydrates. Two lines plus a test.

### 1.2 `isHydrating` is dead code, so the fetch has no visible state

`AppModel.isHydrating(_:)` exists and is documented as the thing that lets the
detail view "say so instead of looking like the item simply has no password"
(`AppModel.swift:700-704`). Nothing calls it — not the detail view, not the
tests. `VaultItemDetailView` receives a `VaultItemDetail` and nothing else.

The consequence is that opening a 1Password item shows a complete-looking item
with no Password row for as long as the CLI takes to answer (a child process, a
biometric prompt, and a round trip — easily seconds), and shows exactly the same
thing forever if the fetch fails, since `hydrateIfNeeded` discards a nil result
silently. The user cannot distinguish "loading", "failed", and "this item has no
password".

### 1.3 A stale write error greets the next edit

`AppModel.writeError` is cleared only when the *next* write begins
(`AppModel.swift:765`, `AppModel.swift:784`). Fail a save, close the sheet, then
open the editor on a different item: the red error from the previous item's
failed save is rendered under the form (`VaultItemEditView.swift:61-67`) before
the user has done anything.

### 1.4 A global `isWriting` closes a sheet someone else's write finished

`VaultItemEditView` closes itself when `appModel.isWriting` goes true → false
with no error (`VaultItemEditView.swift:91-95`). `isWriting` is app-wide and is
also set by `archive(_:)`. Archiving from the toolbar while an edit sheet is
open therefore dismisses the sheet and discards the draft. Narrow, but it
silently destroys typed input.

Relatedly, `save(_:to:)` opens with `guard !isWriting else { return }` — a second
submit is dropped with no feedback at all.

### 1.5 Quick Search searches a frozen list

`ApplicationCoordinator.showQuickSearch` snapshots `quickSearchItems` at
presentation (`ApplicationCoordinator.swift:39-45`) and the panel never updates
while it is open. Two consequences:

- a sync that lands while the panel is up is invisible to it;
- locking *one* of several open vaults leaves that vault's items in the panel,
  because `AppModel.lock(_:)` only dismisses the panel when nothing is left open
  (`AppModel.swift:473-475`).

No secret escapes — `detail(for:)` refuses a closed vault — but the panel
happily lists items from a locked vault and selecting one drops the browser on a
dead selection.

### 1.6 The item list has no empty state

`itemList` is a bare `List(filteredItems)` (`VaultBrowserView.swift:268-276`).
A search that matches nothing produces an empty pane: no message, no "clear
search", nothing. The Quick Search panel gets this right
(`QuickSearchView.swift:57-64`); the main list, where people will actually
search, does not. `ContentUnavailableView.search(text:)` exists on the
deployment target (macOS 14) and is one line.

### 1.7 The search query survives a scope change

`onChange(of: appModel.scope)` resets `selection` but not `query`
(`VaultBrowserView.swift:63-65`). Search for "aws" in All Vaults, click a
folder that has no AWS entry, and the folder appears empty — with the only
explanation being three characters still sitting in the toolbar's search field.
Combined with §1.6 this reads as data loss.

### 1.8 Trailing divider in the detail view

`ForEach(detail.fields) { fieldRow($0); Divider() }`
(`VaultItemDetailView.swift:21-24`) draws a rule below the last field, leaving a
line hanging in the bottom padding.

### 1.9 `favorite` is collected and then thrown away

`VaultItemDraft.favorite` is editable (`VaultItemEditView.swift:33`), is
round-tripped through the write path, and is read back into the draft
(`VaultwardenAccountService.swift:246`). `VaultwardenItemDecryptor.projection`
does not carry it (`VaultwardenItemDecryptor.swift:117-127`), so
`VaultItemProjection` has no favourite field and no list, sort, or badge
anywhere reflects it. The user marks a favourite and the app never mentions it
again. Either surface it or stop offering the toggle.

### 1.10 Unlocking one vault re-opens vaults the user deliberately locked

Every successful Vaultwarden unlock calls `openCredentialFreeVaults()`
(`AppModel.swift:370, 384-388`). The intent is good — one gesture opens the app.
But if the user locks their 1Password vault on purpose and later unlocks
Vaultwarden, the 1Password vault comes back up. Only opening credential-free
vaults that were not explicitly locked in this session would preserve the
intent without overriding a deliberate action.

### 1.11 Smaller things

- **Reveal never auto-conceals.** A revealed password stays on screen until the
  selection changes or the vault locks (up to 15 minutes of inactivity). The
  clipboard expires in 30 seconds; the screen does not.
- **Copying gives no feedback** (`VaultItemDetailView.swift:160-172`). The user
  cannot tell a copy happened, and the 30-second expiry — a real, deliberate
  security control — is invisible.
- **`lock(_:)` clears the clipboard for an unrelated vault**
  (`AppModel.swift:472`): copy from vault A, lock vault B, lose A's copy.
  Defensible, undocumented, and surprising.
- **Reveal/open accessibility identifiers embed user data**:
  `"reveal-\(field.label)"` (`VaultItemDetailView.swift:134`) where the label can
  be a custom field name. UI tests keyed on those are keyed on vault content.
- **1Password's "Open" is not the default action** while Proton's is
  (`AddAccountView.swift:159` vs `:316`); Return does nothing in the 1Password
  pane.
- **`AutoLockController` counts passive `.mouseMoved` as activity**
  (`AutoLockController.swift:107`). With the app frontmost and the pointer over
  the window, ambient pointer motion defeats the inactivity lock indefinitely.
  Keystrokes, clicks, and scrolls are the honest signals.
- **A second Vaultwarden account silently replaces the first.** Credentials are
  keyed to `.primary`; the add-account form offers no warning that adding
  another Vaultwarden account overwrites the stored one.
- **1Password OTP fields** are read from the field's `value`
  (`OnePasswordReadModel.swift:216`) and rendered through
  `VaultwardenTOTP.generate`. If a given `op` build returns the *generated code*
  rather than the `otpauth://` URI in that slot, the row shows "Unreadable
  one-time code seed". Unverifiable from here; a fallback that displays a
  6–8 digit value as a code costs nothing and removes the failure mode.

---

## 2. Performance and responsiveness

Nothing here is a hang. All of it is the kind of per-frame work that turns a
list into a stuttering list somewhere around a few thousand items — which is an
ordinary vault size, not a pathological one.

### 2.1 `AppModel.items` sorts the whole vault on every access

```swift
var items: [VaultItemProjection] {          // AppModel.swift:139-149
    ...
    return scoped.sorted { ... localizedCaseInsensitiveCompare ... }
}
```

It is a computed property, so every read re-flatMaps and re-sorts with a
localized comparison (the expensive kind). It is read from `filteredItems`, from
the detail pane's placeholder — twice, `VaultBrowserView.swift:451,453` — and
again on each body pass, and every keystroke in the search field triggers a body
pass. Vaultwarden projections are *already* sorted by the same key
(`VaultwardenAccountService.swift:191-193`), so for the common single-vault case
this is a re-sort of sorted data; for the merged case a k-way merge of
pre-sorted arrays is linear.

### 2.2 `VaultSlot.groups` rebuilds two dictionaries per row, per redraw

`groups` (`VaultSlot.swift:122-150`) walks every item in the vault, builds two
dictionaries, and sorts. The sidebar calls it inside `ForEach`
(`VaultBrowserView.swift:123`), and `scopeTitle` calls it again to resolve a
name (`VaultBrowserView.swift:287-288`). That is at least two full passes over
every open vault's items on every sidebar redraw — and the sidebar redraws on
every `AppModel` publish, including each 1-second-ish sync state change. It
should be computed once when `items` is assigned and stored.

### 2.3 Each fetched icon invalidates the entire window

`SiteIconStore.images` is `@Published` and is mutated once per resolved host
(`SiteIconStore.swift:97`). Every row, the sidebar, and the detail view observe
the same `EnvironmentObject`, so N sites in a vault means N full invalidations
of everything, arriving in a burst as the vault opens. This is the most likely
source of visible scroll stutter with site icons on. Coalescing the assignments
into one publish per runloop turn — or holding the images in a non-published
box with a single change counter — removes it without changing behaviour.

### 2.4 The detail view re-decrypts on every render

`appModel.detail(for: selection)` is called from the view body
(`VaultBrowserView.swift:439`), and it does a linear scan of the cipher array
plus an AES-CBC decrypt and HMAC verify per field on every invocation. Any
`AppModel` publish re-runs it. Correct, and never wrong — just work done
hundreds of times where once would do. Memoizing on
(item id, snapshot generation, hydration state) is straightforward.

### 2.5 Search does substring matching over every field, per keystroke

`matches` (`VaultBrowserView.swift:545-549`, duplicated verbatim in
`QuickSearchPanelModel.swift:53-57`) builds an array of haystacks per item and
runs `localizedCaseInsensitiveContains` over each. Allocating the haystack array
per item per keystroke is the avoidable part; the localized comparison is the
expensive part and can be skipped for the ASCII fast path. Also: two copies of
the same function is one copy too many.

### 2.6 The 1 Hz TOTP timeline redraws its whole row

`TimelineView(.periodic(from: .now, by: 1))` (`VaultItemDetailView.swift:140`)
regenerates the code — a full HMAC — every second, when the code only changes
once per period. Cheap in absolute terms; worth noting because the countdown
belongs in a separate, small view so it does not re-run generation.

---

## 3. Interaction: the gestures that do nothing

This is where the app loses the most ground, and it is nearly all cheap.

### 3.1 Quick Search cannot be driven from the keyboard

The panel is a launcher. It opens with ⇧⌘Space, focuses its field correctly
(the focus dance in `QuickSearchView.swift:103-116` is careful and right), and
then: **the arrow keys do nothing, and Return always opens the first result**
(`openFirstResult`, `QuickSearchView.swift:93-96`). There is no selection, no
highlight, and no way to reach result two without the mouse. Every comparable
panel on the platform — Spotlight, Raycast, Alfred, 1Password's own Quick Access
— is arrow-driven. This is the single highest-value fix in the document.

Alongside it:

- **No relevance ranking.** Results are whatever order the vaults produced,
  which is alphabetical, so typing `git` puts "Digital Ocean" above "GitHub".
  Prefix and word-start matches must sort first.
- **No vault attribution.** In a merged multi-vault search two identically named
  logins are indistinguishable. The main list already solved this with a vault
  badge (`VaultBrowserView.swift:312-321`); the panel did not inherit it.
- **No icons, no category, no result count.**
- **An empty query lists everything**, alphabetically, in a 330 pt panel.
  Recently opened items would be a better answer.

### 3.2 There is no context menu anywhere

Right-clicking an item row — in the list or in Quick Search — does nothing. On
macOS, "Copy Password" on the row's context menu is table stakes; today the only
route to a password is select → wait for the detail → aim at a 16 pt icon.

### 3.3 Almost nothing has a keyboard shortcut

Present: ⌘N (add item), ⇧⌘L (lock), ⇧⌘Space (Quick Search), Return (unlock).
Absent: copy username, copy password, copy one-time code, sync, edit, archive,
focus search, open website. For an app whose README promises "keyboard-first
navigation", the keyboard reaches three commands.

### 3.4 Auto-lock is configurable only with `defaults write`

`AutoLockController` implements a full inactivity lock with a 15-minute default
and a `VaultSquire.autoLockMinutes` key (`AutoLockController.swift:24-28`) — and
Settings says, in as many words, that "a configurable global shortcut and lock
policy are enabled only after their interaction and security tests pass"
(`SettingsView.swift:17`). One of those is out of date: the lock policy *is*
running, the user just cannot see it, change it, or discover why the app locked
itself while they were reading. (PR #31 revises this copy; it does not add the
control.)

### 3.5 No password generator

A password manager with a create-item form and no generator is a text editor
with encryption. This is the most conspicuous missing feature in the app.
There is also no reveal toggle on the password field, so a typed or pasted
password cannot be verified before saving, and no strength indication.

### 3.6 Smaller interaction gaps

- No drag-and-drop of a username or password onto another app.
- No "recently used" or "recently viewed" ordering anywhere.
- No sort control (title only), no category filter, no favourites filter.
- No multi-select and no bulk action.
- No item-count badges except in the sidebar's group rows.
- Return in the item list does nothing; Space does nothing.
- The window has no restoration of the last-selected scope (deliberate, given
  the restoration policy — but the *scope*, unlike the selection, is not secret).

---

## 4. Visual and layout

### 4.1 The toolbar status item is fighting the toolbar

`VaultBrowserView.swift:463-492` — a bare relative timestamp ("2 min ago") in
the navigation slot with no label, wrapped in a `fixedSize` and manual padding
whose own comment explains it is compensating for the toolbar's background
capsule. Without the word "Synced" the string is cryptic; with a leading SF
Symbol (`arrow.triangle.2.circlepath`) and a proper label it would read as
intended and stop needing manual padding.

### 4.2 The edit sheet's text editors have no visible bounds

`TextEditor` inside a grouped `Form` (`VaultItemEditView.swift:45, 55`) renders
with no border and no background on macOS. Both the Websites and Notes fields
look like stray text rather than editable fields. They need a rounded
background and a hairline stroke, matching `.roundedBorder` fields.

### 4.3 The sheet is a fixed 460 × 560 and the Settings window a fixed 540 × 340

`VaultItemEditView.swift:88` and `SettingsView.swift:52`. The Settings Privacy
tab holds four `fixedSize` paragraphs, a toggle, and a divider inside 340 pt of
height; at the default text size it is tight, and at any increased text size it
clips. Neither window should be pinned to a magic number.

### 4.4 Density and truncation in the item row

The vault badge shares a line with the subtitle (`VaultBrowserView.swift:303-321`)
and wins the space contest on a narrow window, truncating the username — which
is the more useful of the two. Rows are also uniformly 2 pt-padded with no
density option; a password manager list benefits from a compact mode.

### 4.5 The sidebar's summary line reads as a fragment

`"\(count) items in \(open) open"` (`AppModel.swift:149-153`) — "142 items in 2
open". "142 items · 2 vaults open" says the same thing and parses.

### 4.6 There is no offline / cache indication

Both CLI providers and Vaultwarden fall back to a sealed local snapshot, and
the UI never says so. A "showing the last synced copy" badge is both honest and
reassuring, and it is the natural home for the sync error string that currently
lives as a truncated toolbar label.

### 4.7 Locked vault pane is a left-aligned wall

`lockedVaultPane` (`VaultBrowserView.swift:331-419`) is a plain top-left VStack
in a wide pane: a title, a subtitle, a 320 pt field, and buttons, with the rest
of the pane empty. Centred in a card, with the provider's mark, it would read as
a designed state rather than an unfinished one.

### 4.8 The one genuinely handsome screen is the one users see once

The empty shell's identity rail (`LockedShellView.swift:54-92`) — gradient,
tracked small caps, shield — is the only piece of art direction in the app, and
it is only ever shown before the first account exists. Everything after that is
default SwiftUI. The rail's vocabulary should carry into the browser: the
locked pane, the empty detail, the Quick Search header.

*(Worth checking on-device: the rail sets `.foregroundStyle(.white)` on the
container and `.secondary` on two descendants. Modern SwiftUI derives
hierarchical styles from the set foreground style, in which case this is correct
white-at-reduced-opacity; if it instead resolves against the colour scheme, the
tagline is near-black on dark navy in Light Mode. A visual check settles it.)*

---

## 5. Missing features, roughly by value

1. **Password generator** — with length, character classes, a passphrase mode,
   and one-click "use this". §3.5.
2. **Configurable auto-lock**, plus "lock on sleep/screensaver" visibility. §3.4.
3. **Favourites** — the data is already collected. §1.9.
4. **Vault health**: reused, weak, and short passwords, and items with no
   one-time code. Entirely local, works across all three providers, and is the
   kind of feature that justifies a native client over a browser extension.
5. **Recently used / recently viewed**, feeding both the item list and the empty
   Quick Search state.
6. **Delete and trash for Vaultwarden**, which currently offers archive only.
7. **Password history** — Vaultwarden preserves it in the cipher and the write
   path is careful to keep it; nothing displays it.
8. **Item types beyond login for create/edit** — secure notes at minimum.
9. **Folder management** (create, rename, move an item) — folders are read-only
   today.
10. **A menu bar extra**: search, copy a one-time code, lock — without raising
    the window.
11. **Export** of non-secret metadata for auditing, or an explicit "no export by
    design" statement in Settings so the absence reads as a decision.
12. **Per-item "reprompt"** — Vaultwarden's `reprompt` flag is preserved on write
    and ignored on read.

---

## 6. Making it look like an app worth paying for

Concrete, and in rough order of effect per hour:

- **A real empty/selection state.** The detail placeholder is currently
  `ContentUnavailableView` with an item count as its *description*
  (`VaultBrowserView.swift:447-455`), which is where a count should never live.
  Replace it with the app's mark, the scope name, and the two or three actions
  that make sense there.
- **One accent per provider.** Vaultwarden, Proton, and 1Password each get a
  tint used for the vault's sidebar icon and its locked pane. Merged lists
  become readable at a glance, and it costs one dictionary.
- **A TOTP ring.** Replace the "23s" caption with a thin circular progress ring
  around the code that drains and flips amber under five seconds. It is the
  single most recognisable "this app is well made" detail in this category.
- **Copy feedback.** A brief checkmark on the button plus a countdown pill —
  "clears in 24s" — turns an invisible security control into a visible feature.
- **Monospaced, grouped secrets.** Passwords render in `.body.monospaced()`
  already; group them in four-character runs with subtle colouring for digits
  and symbols, which is how people actually read a password aloud.
- **Materials, not flat panes.** The Quick Search panel uses `.regularMaterial`
  and looks the part; the sidebar should use `.sidebar` list style with a
  material background, and the detail should sit on a subtle elevated surface.
- **Typography discipline.** The app mixes `.largeTitle`, `.title2`,
  `.system(size: 34)`, and `.system(.title3, design: .rounded)` across four
  screens. Pick one scale — rounded for display, default for content — and
  apply it everywhere.
- **Motion.** There is exactly one animation in the app (the sidebar twisty,
  `VaultBrowserView.swift:196`). A vault opening, an item's fields appearing,
  and the lock closing all deserve a short, snappy transition. The lock is the
  emotional beat of a password manager and it currently happens instantly and
  invisibly.
- **A proper "locked" treatment.** When everything locks while the window is
  open, blur the content behind a material and put the unlock affordance on top,
  rather than swapping to a different layout.

---

## 7. Novel, quirky, and delightful

- **The Squire.** The app has a name and a heraldic shield and does nothing with
  either. A small heraldic mark that latches shut on lock — one 200 ms
  animation — would give the app a signature moment. Quiet, not cute.
- **Clipboard countdown in the menu bar.** While a copied secret is live, show a
  tiny draining ring in the menu bar extra. Click it to clear immediately. It
  makes the app's best-hidden security property its most visible one.
- **Screenshot shyness.** While a secret is revealed, set the window's
  `sharingType` to `.none` so screen recordings and screenshots capture a blank
  pane. One line, and it is the kind of thing users tell each other about.
- **Type-to-find in the item list.** Focus the list and start typing: filter
  immediately, no ⌘F. It is how the Finder behaves and how nothing else in this
  category does.
- **Peek with Space.** Select a row, tap Space, get a floating card with the
  username and a copy button, without leaving the list.
- **"Only shown once" reveal.** Revealing a secret starts a 20-second ring on
  the field itself; when it drains, the field re-conceals. Reveal becomes a
  deliberate, bounded act instead of a toggle someone forgets.
- **Vault weather.** A single line in the sidebar footer: "3 reused · 1 weak ·
  synced 2 min ago". Local, honest, and a reason to open the app when you don't
  need a password.
- **Drag a login onto a browser window** to copy the username; hold ⌥ to copy
  the password. Both go through `ClipboardService` and keep the expiry.
- **A "second pair of eyes" mode.** ⌥-hover any secret to reveal it only while
  held, so nothing is left on screen.
- **Honest offline mode.** When the network is gone, say so in the sidebar and
  keep working from the sealed snapshot with a dated badge, rather than
  surfacing a truncated error string in the toolbar.
- **Provider parity table in Settings.** A small grid showing exactly which
  actions each connected provider supports and why the others are absent. The
  capability model already knows the answer; showing it turns a limitation into
  an act of transparency.

---

## 8. What is being implemented now

Ranked by (confidence × value) ÷ blast radius. Each lands on its own branch.

| # | Change | Sections |
|---|--------|----------|
| 1 | Quick Search: arrow-key navigation, relevance ranking, vault labels, result count | 3.1, 2.5 |
| 2 | Detail view: copy feedback with expiry countdown, TOTP ring, hydration state, auto-conceal, ⌘C/⇧⌘C, no trailing rule | 1.2, 1.8, 1.11, 2.6, 6 |
| 3 | Item list: context menus, ⌘R/⌘E/⌘F shortcuts, no-results state, query reset on scope change | 1.6, 1.7, 3.2, 3.3 |
| 4 | Invalidate CLI item content on sync; clear stale write errors | 1.1, 1.3 |
| 5 | Sidebar/list performance: memoised groups, no double sort, coalesced icon publishes | 2.1, 2.2, 2.3 |
| 6 | Settings: auto-lock control, honest copy, self-sizing window | 3.4, 4.3 |
| 7 | Password generator with strength meter, reveal toggle, and bordered editors in the edit sheet | 3.5, 4.2 |

Deliberately **not** attempted here: anything needing on-device verification
(materials, motion, the identity-rail contrast check), anything touching the
provider protocols, and anything that would collide head-on with the 95-file
PR #30.
