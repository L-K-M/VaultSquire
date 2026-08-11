# GLM Review — VaultSquire

A thorough review of the VaultSquire codebase (≈14.7k LOC of Swift + ≈10.2k LOC
of tests) covering bugs, general issues, performance, missing features, visual
and layout problems, UX, aesthetics, and ideas for delightful improvements.

This is a **review document**, not a controlling document. It is subordinate to
`PLAN.md`, `SECURITY_AND_TESTING.md`, and `ARCHITECTURE.md`. Nothing here is
intended to relax a security invariant; where an idea would, it is flagged and
left out of implementation.

Findings are tagged with a confidence/value pair and a **risk** note, because
the authoring environment is Linux and cannot compile Swift (per `AGENTS.md`,
this environment verifies only documentation and repository hygiene). Every
Swift change therefore still needs macOS/Xcode verification, which is the
documented norm for this repo.

---

## 1. Bugs and correctness

### B1. Auto-lock can fire up to ~7.5 minutes late with the default timeout
`AutoLockController.armInactivityCheck()` computes the check interval as
`max(60, inactivityTimeout / 2)`. With the default 15-minute timeout that is
450 s (7.5 min), so a lock can land up to 7.5 minutes *after* the configured
boundary. The comment claims the interval is "never more often than once a
minute," but for a 15-min budget it is in fact every 7.5 min. A password
manager that promises "lock after N minutes" should not be off by half of N.

**Fix idea:** cap the interval at a small constant (e.g. 30–60 s) regardless of
the budget, so the lock lands within one tick of the boundary. The cost is one
no-op timer wake per minute, which is negligible.
File: `VaultSquire/App/AutoLockController.swift`.

### B2. Typed-but-unsubmitted master password lingers across vault switches
`VaultBrowserView` keeps per-vault draft passwords in `@State passwords:
[AccountID: String]` and only clears an entry inside `submitUnlock` (on
submit). If a user types a password, then clicks another vault in the sidebar
without submitting, that `String` survives in process memory indefinitely
(until a successful submit elsewhere or app termination). The per-vault map is a
nice UX touch, but for a security-focused app the plaintext should be cleared
on selection change and on lock, not only on submit.

**Fix idea:** clear `passwords[account]` when the user navigates away from a
locked-vault pane, and clear the whole dict on `appModel` lock. Consider a
short defer-zeroize like the unlock path uses (though `String` is not reliably
zeroable in Swift; clearing the reference is the realistic control).
File: `VaultSquire/Features/Vault/VaultBrowserView.swift`.

### B3. Search query survives a vault-scope change
`VaultBrowserView` clears `selection` on `onChange(of: appModel.scope)` but
does not clear `query`. Switching from "All Vaults" to a single vault (or vice
versa) keeps the old filter text applied, which is usually surprising. Quick
Search is a fresh panel each time, so it does not have this issue; the browser
does.

**Fix idea:** also reset `query = ""` in the scope-change handler.
File: `VaultSquire/Features/Vault/VaultBrowserView.swift`.

### B4. Stale selection can outlive a filtered-out item
The item list binds `selection: $selection` over `filteredItems`, but
`selection` is only cleared on scope change. If you select an item, then type a
query that hides it, `selection` still holds its id and the detail pane keeps
showing it (it is still resolvable via `appModel.detail(for:)` because it is in
`appModel.items`). Not a leak, but the detail pane and the highlighted row can
disagree with what is visible. Minor, but worth a guard so the selection tracks
the visible list.

**Fix idea:** when `filteredItems` no longer contains `selection`, clear it.
File: `VaultSquire/Features/Vault/VaultBrowserView.swift`.

### B5. TOTP countdown uses ceiling round, can show a confusing "1s" at the wire
`totpRow` computes `remaining = max(0, Int(...rounded(.up)))`. Right at window
roll-over the `TimelineView` briefly still renders the old `Generated` until
its next tick, so a user can see `1s` persist for up to a second after the code
already rolled. Cosmetic, but in authenticator UIs users key off the countdown
to know *when* to copy. A floor round + showing the new code as soon as the
window flips would feel more precise.

### B6. `spacedCode` only spaces 6-digit codes
`VaultItemDetailView.spacedCode` guards `code.count == 6`. The TOTP parser
allows 6–8 digits (`VaultwardenTOTP.parse`), so 7- and 8-digit codes render
unspaced. Spacing a long code in groups (e.g. 4+4 for 8) is more legible.

### B7. `onChange(of: appModel.isWriting)` closes the edit sheet on *any* write finishing
`VaultItemEditView` watches the global `appModel.isWriting` flag and closes the
sheet when a write completes without error. The sheet is modal so only one
write runs at a time today, but the coupling is implicit and fragile: any
future background write that toggles the flag would dismiss the sheet
unexpectedly. Prefer correlating on the specific draft/save (e.g. an id or a
"last saved item" published value) rather than the global flag.
File: `VaultSquire/Features/Vault/VaultItemEditView.swift`.

### B8. Quick Search snapshot can go stale while the panel is open
`QuickSearchPanelController.show()` snapshots `items` and `isUnlocked` once at
presentation. If a sync lands, a vault locks, or the user adds an item while the
panel is open, the panel keeps showing the old set. Low severity (panels are
short-lived), but worth either re-snapshotting on a timer / focus event or
having the model publish updates.

### B9. Site-icon fetch failures are permanent for the session
`SiteIconStore.load()` inserts the host into `attemptedHosts` *before* the
await, so a transient network failure or a timeout on a slow-but-valid icon
disables that icon until the app restarts. A single bad moment (flaky Wi-Fi at
vault open) means a perfectly good favicon never appears. Consider a bounded
retry or distinguishing "fetched and empty" from "fetch errored."
File: `VaultSquire/Features/Vault/SiteIconStore.swift`.

### B10. Quick Search claims a "global" shortcut but the hotkey is app-level
`VaultSquireApp` registers ⌘⇧Space and ⌘⇧L as **menu command** shortcuts, and
Settings advertises "App shortcut: Command-Shift-Space." Menu shortcuts only
fire when VaultSquire is frontmost, so this is not the Spotlight/Raycast-style
system-wide hotkey the feature name implies. Either rename to "app-wide" or
implement a true global hotkey (see M5). This is both a bug-ish surprise and a
missing feature.

---

## 2. General / architectural issues

### G1. No way to remove or reconfigure an account from the UI
`AccountDescriptorStore.remove(_:)` and credential deletion exist, but nothing
in the UI calls them. A user who wants to drop a Vaultwarden account, re-add a
signed-out CLI vault, or recover from a "session expired — add the account
again" message has no in-app path. For a multi-provider manager this is a
significant gap and a likely support burden.

### G2. Only one Vaultwarden account is supported
`AccountID.vaultwardenPrimary` is hardcoded. The code comments acknowledge this
is a workstream limitation. Real users with a personal and a shared/work
Vaultwarden server cannot use both. Multi-account is modelled in the domain
layer but not wired through.

### G3. Editing and creating are login-only
`VaultItemDraft` and `VaultItemEditView` only handle logins. Cards, identities,
and secure notes are view-only. Creating a secure note — the second most common
item type — is impossible. `VaultwardenItemDecryptor.detail` already decodes
cards/identities, so the read side is ready; the write side is not.

### G4. Custom fields cannot be created or edited
`VaultItemDraft` carries no custom fields. An edit preserves them verbatim (good),
but a user cannot add, edit, reorder, or delete custom fields, which for many
imported vaults carry the bulk of the real content (license keys, serials, PINs).

### G5. No Trash / Archive view or restore
Archived and trashed ciphers are excluded from lists and detail
(`VaultwardenItemDecryptor`). There is no UI to view or restore them, so a
mistaken archive forces a trip to the web vault. Restore is in the capability
enum (`restoreItem`) but unused.

### G6. Favorites are settable but not filterable
The edit sheet has a Favorite toggle and ciphers carry `favorite`, but there is
no favorites scope, filter, or star indicator in the list. The capability
`favoriteItem` exists but is not used.

### G7. No sort options
Items are always alphabetical by title. There is no "recently used," "date
modified," "by folder," or "by type" ordering. For large vaults this makes
re-finding things harder than it should be.

### G8. No password generator
A core password-manager feature. The edit sheet asks the user to type or paste
a password. A built-in generator (random + memorable + pronounceable) with a
strength meter would materially improve the create/edit flow and is a clear
"high-value macOS app" expectation.

### G9. No right-click / context menu on items
Rows support click-to-select and double-click-to-open (via selection), but
there is no context menu for the common one-shot actions: copy username, copy
password, copy one-time code, open website, favorite, archive. These are the
highest-frequency interactions in a password manager and currently all require
opening the detail pane.

### G10. No keyboard shortcuts for the common copy actions
Beyond ⌘⇧Space/⌘⇧L, there are no shortcuts for copy-username, copy-password,
copy-TOTP, or open-website from the selected item. A keyboard-first manager
lives and dies on these.

### G11. Settings has no auto-lock timing or clipboard-timing controls
`AutoLockController` already supports a configurable inactivity timeout via
`UserDefaults`, and `ClipboardService` accepts an expiry, but neither is exposed
in Settings (the copy says these land "after their interaction and security
tests pass"). Exposing them (with safe ranges) would let users tune the
security/ergonomics tradeoff.

### G12. Locked shell uses hardcoded RGB rather than semantic colors
`LockedShellView.identityRail` paints a fixed dark teal gradient
(`Color(red: 0.10, green: 0.16, blue: 0.21)` → `0.18/0.25/0.29`). It does not
adapt to Light/Dark appearance, so in Light mode the rail is a dark slab next to
a light content area (probably intended) but the secondary text color and
contrast are not tuned for it. Use semantic materials / `Color.adaptable` or at
least test both appearances.

### G13. No health / audit view
No "weak or reused passwords," "expiring cards," "items with no TOTP that
should," etc. This is a popular high-value feature, though any network-based
breach check conflicts with the strict privacy stance and must be opt-in only
(or omitted).

### G14. Drag-and-drop not supported
You cannot drag a password to another app, drag an item into a folder, or
reorder. macOS-native expectations.

---

## 3. Performance

### P1. `AppModel.items` re-sorts on every access
`items` is a computed property that `flatMap`s the scoped sessions and then
`.sorted { ... localizedCaseInsensitiveCompare ... }`. SwiftUI evaluates `body`
on every state change, and `filteredItems` (in `VaultBrowserView`) reads
`appModel.items` — so every keystroke in the search box re-sorts the full scoped
set before filtering. For a vault with thousands of items this is real stutter
on each keypress.

**Fix idea:** sort once when items are produced (in `finishOpen`/`syncNow`/the
session's `items` setter), and store the sorted array on the `VaultSlot`. Then
`items` is a flat concat + (cheap) re-sort only when merging multiple vaults in
"All Vaults" scope — or keep that merge-sorted but skip it for single-vault
scope.
File: `VaultSquire/App/AppModel.swift` (`items`, `scopedSessions`).

### P2. Chained computed properties recompute repeatedly
`scopedSessions` → `items` → `filteredItems` each re-evaluate on access, and
several toolbar/sidebar reads also call `scopedSessions`. Memoize per
`@Published` cycle (e.g. compute once into a `@Published` derived value, or use
`.map` on a publisher) rather than recomputing at each property touch.

### P3. Main list has no search debounce
`filteredItems` runs synchronously on every keystroke. For large vaults a short
debounce (≈80–120 ms) keeps typing responsive while the filter catches up. The
rendering itself is virtualized by `List`, so the cost is the filter+sort, not
view materialization.

### P4. Quick Search filters on the main actor per keystroke with no debounce
Same as P3 but in the panel. Results are typically small so it is less urgent,
but a debounce + keystroke-coalesced filter keeps the panel feeling instant on
huge merged vaults.

### P5. `ItemIconView` `.task(id: identity.host)` is fine, but re-renders are not free
The task only restarts when `identity.host` changes (good), but every list row
rebuilds its `ItemIconView` body on each list invalidation. For very large lists
consider an `.equatable()` wrapper or extracting the icon into a lightweight
struct that only depends on `identity` + `category` + size, so unrelated state
changes do not re-render the icon.

---

## 4. Missing features (product-level)

### M1. Password generator (random / memorable / pronounceable) with strength meter
See G8. Highest-leverage missing feature.

### M2. Global system-wide Quick Search hotkey (Spotlight/Raycast-style)
See B10. Requires a real global shortcut (e.g. Carbon `RegisterEventHotKey` or a
modern equivalent), with privacy and accessibility-prompt implications that need
to be reconciled with `SECURITY_AND_TESTING.md`.

### M3. Keyboard-navigable Quick Search (↑/↓ to move, ↩ to open, ⌘↩ copy password, etc.)
The panel today has Enter-opens-first and click-to-open only. Arrow-key
navigation with a visible selection is essential for a "quick" search.

### M4. Item icons in Quick Search results
`VaultItemProjection` already exposes `iconIdentity` (via the extension on
`ItemIconIdentity`), and `SiteIconStore` is injected. Quick Search rows render
only title/subtitle today — adding the same `ItemIconView` the main list uses
makes results instantly scannable and visually consistent.

### M5. Menu-bar item / mini-mode
A menu-bar icon that opens Quick Search or offers copy-username/password for
recent items without raising the full window. Classic macOS power-user feature.

### M6. Favorites scope + star indicator
See G6.

### M7. Trash / Archive view with restore
See G5.

### M8. Multi-account Vaultwarden
See G2.

### M9. Passkey support
Capability `usePasskeys` is declared but unused.

### M10. Attachments (view at minimum)
Not modelled in the projection.

### M11. Fuzzy / subsequence search with ranking
Current matching is plain `localizedCaseInsensitiveContains` (substring only).
Subsequence matching with a rank score (like fzf/Spotlight) is more forgiving
("gh" matches "GitHub") and feels faster. The two duplicate `matches(_:)`
helpers (`VaultBrowserView` and `QuickSearchPanelModel`) should be centralized.

### M12. Recently-used / frecency ordering
Track last-opened/copied timestamps (in memory, or in the non-secret descriptor
store) and offer a "Recent" scope and a frecency-ranked Quick Search.

### M13. Search qualifiers (`type:card`, `fav:`, `vault:Work`)
Once fuzzy search lands, adding a few prefix qualifiers covers most power-user
filtering without a dedicated filter UI.

### M14. Copy-one-time-code from the list / Quick Search without opening detail
High-frequency action. Requires surfacing whether an item has a TOTP seed
(non-secret boolean on the projection) and computing the code on demand — the
seed itself must never leave the detail/hydration path.

### M15. Notes preview / markdown rendering for secure notes
Secure notes currently render as a single plain `.plain` field. Markdown
rendering (read-only) would be a nice touch, with the raw text on copy.

### M16. Apple Watch unlock
`LAContext` supports `.deviceOwnerAuthenticationWithBiometrics` plus Watch
unlock via `LAPolicy.deviceOwnerAuthentication`. Extending Touch ID unlock to
also accept Watch is low-effort and very "Mac."

### M17. Onboarding polish for the empty shell
The empty state is two buttons and a sentence. A short, friendly first-run
explainer (especially for the CLI providers, which are unusual) would reduce
the "what do I do here" moment.

---

## 5. Visual issues and layout problems

### V1. Locked-shell identity rail is a fixed dark slab in both appearances
See G12. The gradient and text colors are hardcoded and not tuned for Light/Dark.

### V2. Detail field labels are uppercased and heavy
`VaultItemDetailView.fieldRow` uses `.font(.caption.weight(.semibold)).textCase(.uppercase)`
for every label. Modern macOS detail surfaces (e.g. Settings, Mail, Notes) tend
toward sentence-case, lighter-weight section labels. The all-caps treatment
reads as utilitarian and slightly dated. Consider title/sentence case with a
`subheadline` weight, reserving caps for metadata.

### V3. Detail layout is a flat field-and-divider list
Functional but plain. A grouped "card" layout (rounded background per section,
like macOS Settings) would read as higher-value and improve scannability for
items with many fields/custom fields.

### V4. Detail header icon (46pt) vs `.largeTitle` title feels unbalanced
Either enlarge the icon or step the title down to `.title` for better optical
balance. A subtle drop shadow or rounded background on the icon would also help
it read as a "tile" rather than a floating glyph.

### V5. TOTP row has no progress affordance
The code is `.title3.monospaced()` with a tiny `Xs` countdown beside it. A
circular progress ring (shrinking arc over the 30s window) is the convention in
authenticator apps and 1Password/Bitwarden, and immediately tells you whether
the code is about to roll.

### V6. Secret reveal uses a fixed 10-bullet mask
`"••••••••••"` regardless of actual length. A length-aware mask (or a fixed
monospaced block) is more honest and avoids the "is it really there?" doubt.

### V7. Toolbar status bubble needs a `fixedSize` hack
The comment in `VaultBrowserView.toolbarContent` explains the
`.padding(.horizontal, 7).fixedSize(...)` workaround for the toolbar capsule
compressing the label. This is fragile; a cleaner approach is a dedicated
`ToolbarItem` with a `Label` or a fixed-width status pill built as its own
view, so it does not depend on the system capsule's sizing.

### V8. Sidebar disclosure is a hand-rolled chevron
The custom chevron-button was chosen because `DisclosureGroup`'s triangle
top-aligns on a two-line row. Reasonable, but the rotation animation and hit
target could be refined (larger tappable area, spring rotation, alignment with
the system triangle's visual weight).

### V9. Quick Search panel is visually bare
Compared to Spotlight/Alfred/Raycast: no icons, no category glyphs, no keyboard
hints, no sectioning, no "recents" when the query is empty. The empty-query
state currently shows *all* items as an undifferentiated list; showing recent
or frequent items first is friendlier.

### V10. Edit sheet is a small fixed 460×560 form
The website and notes `TextEditor`s are 54 and 70 points tall — cramped for
real content. A taller default with expanding editors, plus a live URL
preview/normalization hint, would feel more capable.

### V11. "All Vaults" merged-list source badges are plain capsules
The per-vault badge in a merged list is a secondary-colored capsule. It works,
but a subtle tinted dot keyed off the vault's identity (like the item-icon hue
derivation) would be more scannable and prettier.

### V12. No empty state for the main list when search yields nothing
`itemList` just becomes an empty `List`. A `ContentUnavailableView` ("No items
match '…'") matching the Quick Search treatment would be consistent and less
broken-looking.

### V13. Color palette is minimal
Mostly accent + secondary grays. A restrained but richer palette (per-category
tints on icons, a brand-tinted locked shell, subtle gradients on key surfaces)
would lift the perceived value without compromising the serious-tool tone.

---

## 6. UX, convenience, and "fast"

### U1. One-tap copy from the list row
Hover-to-reveal copy buttons on each list row (copy username / copy password)
remove the detail-pane round-trip for the single most common action. Combined
with a context menu (G9) this transforms daily use.

### U2. Double-click a row to open its first website
Common pattern; currently double-click only selects.

### U3. ⏎ on a selected list row opens detail; ⌘⏎ opens website; ⌘C copies username
Keyboard-first detail navigation and copy.

### U4. "Open & copy password" as a single Quick Search action
Selecting a login in Quick Search and pressing ⌘⏎ could open the site *and*
copy the password to the clipboard — the classic 1Password "Open & Fill"
ergonomic minus the filling.

### U5. Reveal-all toggle in detail
A single control to reveal every concealed field in an item at once, instead of
toggling each. Useful for cards and identities with many secrets.

### U6. Copy field value by clicking the value text
Currently copy is a dedicated icon button. Allowing click-on-value to copy (with
a toast) is faster and matches several native Mac apps.

### U7. Show field-specific copy confirmation
No feedback today that a copy succeeded. A transient "Copied" checkmark or a
brief banner confirms the action, especially important for TOTP where the window
is short.

### U8. Relative "last synced" is good; add a manual "synced just now" confirmation
The toolbar shows relative time, but a Sync press gives no immediate visible
confirmation besides the spinner. A brief "Synced" state would help.

---

## 7. Aesthetics — making it look like a high-value macOS app

### A1. Adopt `.background(.regularMaterial)` and grouped card surfaces in detail
The flat field list reads as a utility app. Grouping fields into rounded,
material-backed cards (with subtle separators) is the single biggest visual
upgrade for low risk.

### A2. Refine the locked shell into a real hero
The empty/locked state is the first impression. A larger, centered composition
with the shield mark, a refined wordmark, and a single primary CTA (plus
secondary text) sets the tone. The current split rail is fine but generic.

### A3. Spring transitions on lock/unlock and reveal
State changes are instant. Subtle spring animations (`.snappy`, `.smooth`) on
reveal/hide, vault open, and sidebar expansion make the app feel alive without
being gimmicky.

### A4. Consistent, generous spacing scale
Spacing varies (28, 24, 22, 20, 14, 12, 8…). A small documented spacing scale
(4/8/12/16/24/32) applied consistently tightens the whole UI.

### A5. Per-category icon tints
Logins, cards, identities, notes, and unsupported each get a faint category
tint behind their SF Symbol, so a glance at a list conveys type. The hue
machinery already exists for site-derived colors; reuse it for categories.

### A6. Polished TOTP presentation
Circular ring (V5) + grouped spacing + copy confirmation (U7) turns the TOTP
row from functional into a highlight.

### A7. Toolbar as a clean status pill
Replace the `fixedSize` workaround (V7) with a purpose-built pill view
(spinning → relative time → error states), consistent in width and padding.

### A8. Selection and hover refinement in lists
A subtler selected-row treatment (accent-tinted leading edge or a soft
accent fill) and a quiet hover affordance on hoverable rows.

---

## 8. Novel, cool, delightful, and quirky ideas

### N1. "Live" TOTP right in the list row — safely
Show the rotating one-time code inline for login rows that have a TOTP seed, so
you can read/copy it without opening detail. **Caveat:** the seed is a secret
and is *not* on the projection today (by design). To do this safely you must
keep seeds out of the projection and decrypt-on-demand per visible row, which is
a real perf/secret-surface tradeoff. A safer cousin: a per-row "has TOTP" dot
and a hover/⌘C copy that hydrates the seed transiently. Flagged as needs-design.

### N2. Vault identity colors
Derive a stable accent per vault (like item-icon hue derivation) and use it for
the sidebar lock glyph, the merged-list source badge, and the Quick Search row
accent. Makes multi-vault scanning much faster and is very pretty.

### N3. Keyboard-driven command palette
Beyond Quick Search, a ⌘⇧P palette for app actions (Lock, Sync, Add Item,
Generate Password, Toggle Site Icons, Settings). Power-users love it; it also
subsumes several missing-shortcut gaps.

### N4. "Breach hygiene" with a privacy-preserving k-anonymity range query
If breach checking is ever wanted, the privacy-preserving pattern is a
k-anonymity SHA-1 prefix range query (the HIBP model). It still sends derived
data out, so it must be opt-in and off by default — but it is the *correct* way
to do it if done at all, and a nice differentiator. Flagged as needs-policy.

### N5. Pronounceable / memorable generator with per-word strength
"correct-horse-battery-staple" style generation, with a live entropy readout,
is both more usable than random strings and a delightful touch.

### N6. TOTP import from image / screen
Drop or paste an image of a QR code; decode the `otpauth://` seed. Macs can use
the camera or a pasted screenshot. Genuinely useful for setting up TOTP on items.

### N7. "Recently copied" clipboard history inside the app (in-memory, cleared on lock)
A tiny, ephemeral, in-app clipboard for the last few copied fields, so a miscopy
or a quick re-copy does not require re-navigating. Cleared on lock like
everything else.

### N8. Subtle "vault open" window chrome accent
When any vault is unlocked, a barely-there accent on the window titlebar / sidebar
bottom (e.g. a thin accent rule or a tiny dot) signals state at a glance, the way
locked keychain apps do. Disappears fully when locked.

### N9. Spotlight-style "recents when empty" in Quick Search
When the query is empty, show recent/frequent items instead of the whole vault —
much faster for the 80% case and visually calmer than a long flat list.

### N10. Drag a login's password straight into a browser field
Drag-and-drop a password (and username) as drag items, so filling a form is a
single gesture without an extension. macOS-native and memorable.

### N11. A "lock" menubar-icon mini-app
Menu-bar item (M5) that lists recent items and one-click copies, fully usable
without ever showing the main window.

### N12. Confetti (or a quiet checkmark) the first time you set up Touch ID
A tiny moment of delight on a security-positive action. Optional and off by
default, but a human touch.

---

## 9. What is genuinely good (so it is preserved)

- **Security posture is coherent and well-documented.** Generation-based late-
  result discard, clipboard ownership/change-count gating, fail-closed CLI
  version gates, no-argv/no-env secret handling, and the site-icon
  "site's own origin, never an aggregator" rule are all principled and
  well-explained in comments. Improvements should not erode these.
- **Capability gating is real**, not just disabled buttons (`CapabilityGate`).
- **Per-vault independent sessions** with merged "All Vaults" scope is the right
  model and well implemented.
- **TOTP** is correct (RFC 6238/4226, Base32, multiple algorithms/digits/periods).
- **Monograms with deterministic hue** are a smart, privacy-respecting default.
- **Extensive test coverage** (≈10k LOC) including leakage and fuzz tests.
- **Accessibility identifiers** are thorough across the UI, which is rare and
  valuable.

---

## 10. Implementation triage (this review)

Implemented in this pass (own branch + PR each), chosen for high value and low
risk given the no-compiler environment — all are additive, view-layer, and
self-contained:

- **Quick Search polish** — item icons, ↑/↓ keyboard navigation with a visible
  selection, ↩ opens the selected (or first) result, and a keyboard-hint footer.
  (B10-adjacent UX, M3, M4, V9.)
- **TOTP circular progress ring** in the detail view — a shrinking arc over the
  code window with the countdown centered, plus spacing for 7/8-digit codes.
  (V5, V6-adjacent, B6, A6.)
- **Browser search/scope polish** — clear the query on scope change, clear a
  stale selection when the filter hides it, and show a `ContentUnavailableView`
  when the filtered list is empty. (B3, B4, V12.)

Items deliberately *not* implemented here because they need design or macOS
verification beyond a view-layer change: password generator (G8/M1), global
hotkey (M2), account removal UI (G1), multi-account (G2), non-login editing
(G3), trash/restore (G5), favorites scope (G6), sort options (G7), context menus
(G9), and the deeper perf rework of `AppModel.items` (P1/P2) which changes
state flow and should be verified with the performance fixtures on a Mac.

These remaining items are carried into `ANALYSIS.md` as the basis for future
work.
