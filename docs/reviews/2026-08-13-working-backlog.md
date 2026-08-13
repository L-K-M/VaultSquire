# ANALYSIS — VaultSquire working backlog

Merged from the sol review pass on 2026-08-12. It combines the pass's full
review ([`2026-08-12-sol-review.md`](2026-08-12-sol-review.md), review base
`905d76d`, status re-derived against
`f48084e`) with the eight parallel reviews recorded in
[`2026-08-12-consolidated-backlog.md`](2026-08-12-consolidated-backlog.md), which
this document supersedes as the live list.
Nothing from either source is discarded: entries that are now done are
recorded in the Done table below with what closed them, and every open entry
keeps its origin codes (`VS-…`, `B…`, `#72`, `S-…`, …) so a reader can trace
any item back to the review that found it.

- **Environment:** Linux. Nothing here was compiled or executed locally; the
  hosted `macOS Product` lane (`./scripts/ci.sh` on `macos-26`) is the
  executing gate for every code claim. No macOS, accessibility, performance,
  or hardware claim is made from this environment.
- **Clean-room attestation:** this pass inspected no production vault
  material, no vendor credentials, no CLI output from a real machine, and no
  Keyguard-derived or pre-export history. All examples are synthetic. The
  attestation travels with this document and with the sol review.
- **Conflict rule:** `PLAN.md` controls scope and sequence,
  `SECURITY_AND_TESTING.md` controls security invariants and release gates,
  `ARCHITECTURE.md` controls component/data boundaries. A conflict among
  those three blocks implementation.

## Done — cleared from the backlog

An item appears here when its pull request is merged **and** its evidence is
linked; "an open PR is green" earns a seat at the bottom of this table, not a
claim of support. Items re-enter the backlog if their PRs are rejected.

### Merged while the review pass ran

| What | Closed |
|---|---|
| #79 (maintainer merge, `f48084e`) | Global system-wide Quick Search hotkey with a chord recorder in Settings (M2, B10, VS-032, #66 M1; updates `docs/dependencies/keyboard-shortcuts.md`). Quick Search copy actions with honest outcomes — Return runs the item's primary action, ⇧Return/⌥Return copy username/one-time code, ⌘Return shows the item, footer reports fetch failures instead of failing silently (U4, D2, #47 panel half). Window-sizing fixes: content-column width floor, scrolling locked-vault pane with a width floor, Settings prose width cap and stated default window size (the Settings-wider-than-the-screen failure; #48 34 and the edit-sheet size of VS-036 remain open). |

### Implemented in this pass — PRs open, CI green at the time of writing

| PR | Closed |
|---|---|
| #80 | Pointer motion no longer counts as idle activity; `AutoLockController.activityEventMask` excludes `.mouseMoved`, pinned by a test; Settings copy updated (#72, VS-023). |
| #81 | The unlock gesture honors deliberate per-vault locks — a hand-locked CLI vault is not reopened by an unrelated unlock (`lockedByUser`, VS-068); a visible Quick Search panel refreshes after every successful open and sync (B8). |
| #82 | `allOpenItems` cached instead of re-sorted per access (S-05); `mutate` gates its group/list rebuilds on the values they derive from (S-06); the selected Vaultwarden item's detail and draft are memoized per snapshot generation, dropped on close (S-07, the per-redraw half of P4). |
| #83 | Double-click a row opens its first website behind the URI confirmation (U2); sidebar summary reads "142 items · 2 vaults open" (#72); the detail placeholder no longer puts an item count in its description (#72). |
| #84 | Length-aware secret mask, capped at twelve bullets (V6); index-based accessibility identifiers for reveal/open-URI buttons, no vault content in identifiers (VS-067); distinguishing reveal-button accessibility labels (#47); TOTP regenerated once per period instead of once per second (VS-025). |
| #85 | Site icons: one transient failure per host is forgiven, then the host is left alone (B9); a full cache evicts the oldest icon instead of freezing (B8); in-flight fetches capped at six without losing refused hosts (VS-024). |
| #86 | `scripts/check-repository.sh` preflights every tool it uses with one actionable message (VS-048). |

---

## The backlog

Ordered by urgency within each group. Everything below is open.

## 1. Security — release gates (design-first, not pick-up work)

These are gates in `RELEASE_ELIGIBILITY.md` / `SECURITY_AND_TESTING.md`; none
changed status in this pass.

- **Master-password reprompt is not enforced.** `requiresReprompt` is
  preserved on the wire model, but reveal, copy, edit and archive never ask
  for fresh authentication; quick unlock or an already-open session satisfies
  them. Add negative tests for every action path. *(VS-011, R2, #48 2, #72)*
- **Key-rotation reauthentication is incomplete.** Sync no longer absorbs
  rotated key material (the safe half). The rest — detect the rotation,
  persist `reauthenticationRequired`, retain the prior complete snapshot,
  invalidate quick unlock, refuse secret operations, clear only on a complete
  reauth — does not exist, and the next unlock can misleadingly report a bad
  password. One transaction, with crash and cancellation tests. *(VS-004, R1,
  #48 3)*
- **CLI cache-envelope keys are not bound to user presence.** They use an
  ordinary device-only Keychain item. The snapshots omit secret values but
  disclose account inventory, titles, usernames, addresses and vault names.
  *(VS-010, R3, #48 4)*
- **CLI executable identity rests on path and self-reported version.** A
  replaced `pass-cli` or `op` at an allowlisted path can claim an admitted
  version. Require code signature, team identity, designated requirement and
  notarization assessment of the resolved executable, persist the approved
  identity, and detect replacement. *(VS-009, R4, #48 5)*
- **`sessionExpired` is displayed as an error, not a state transition.** A
  revoked refresh token leaves the decrypted vault open on screen and permits
  repeated doomed operations. *(VS-049)*
- **Local persistence failures are reported as network success.** A failed
  rotated refresh-token replacement and a failed `vaultCache.save` are both
  ignored (`try?`) while the fresh snapshot returns as success, so the UI
  shows data that was never durably sealed. *(VS-050)*
- **Initial sign-in reports success without a complete first snapshot.**
  `persistAfterLogin` seeds an empty snapshot best-effort, so a first unlock
  can present an empty vault under "Account Added". *(VS-003)*
- **No secure logout or account-removal transaction.**
  `AccountDescriptorStore.remove` exists and is dead code; nothing deletes
  tokens, descriptors, cache files, biometric envelopes or CLI cache keys.
  *(VS-012, G1, #48 15)*
- **Untested CLI releases sit in the production allowlists** — Proton admits
  2.2.3–2.2.6 and 1Password five stable releases, with in-code comments
  saying none was exercised against a live CLI. Empty is the safe
  pre-evidence state. *(VS-001)*
- **Vaultwarden create/update/archive are exposed before their conflict,
  ambiguity, leakage and official-client evidence exists.** *(VS-002)*
- **Real-provider compatibility is unproven.** Both CLI mappings are tested
  only through fake executors, the 1Password GUI-without-a-TTY authorization
  path is unresolved, and the Vaultwarden cross-client crypto differential is
  outstanding. *(#33 7, #48 7)*
- **Account email is persisted to `UserDefaults`** in the descriptor while
  the security plan treats account identifiers as high sensitivity. Needs an
  explicit reconciliation in a controlling document. *(VS-015)*
- **The lock-timeout default of 15 minutes differs from the plan's
  recommended 5.** Reconcile the number or the plan. *(#48 41)*

## 2. Correctness

- **Vaultwarden `collections` are never decoded.** A cipher's
  `collectionIds` is preserved for write pass-through and nothing else; an
  organization item filed only under a collection gets empty
  `groupingLabels` and is invisible to sidebar grouping and collection
  search, though `PLAN.md` lists collections in scope. *(#47)*
- **Empty Proton and 1Password vaults never appear in the sidebar.** Groups
  derive from items alone; the snapshots carry the vault list — seed groups
  from it. *(ds-B11)*
- **Vault count is silently capped at 50** for both CLI providers, with no
  error, count, or "and N more". *(#47)*
- **Transport failure claims the change was not saved**, but a connection can
  fail after the server commits. Distinguish pre-send from ambiguous failure,
  keep the draft, and block blind retry pending an authoritative read.
  *(VS-018, #48 11)*
- **`VaultSession`/`SessionState` is a fully tested state machine production
  code does not use.** Wire it in as the single authority or delete it and
  move its invariants to the live model. *(VS-059, ds-21)*
- **A second Vaultwarden account silently replaces the first.** Credentials
  are keyed to `AccountID.vaultwardenPrimary` and the add-account form offers
  itself again with no warning. *(G2, M8, #48 16, #72)*
- **A second submit is dropped in silence.** `save(_:to:)` opens with
  `guard !isWriting else { return }`. Narrow (the button disables) but the
  guard should not be the only answer. *(#72)*
- **Archived and trashed items cannot be browsed or restored.** Archiving now
  confirms and says where to restore from, but `restoreItem` is unused and
  there is no Archived or Trash filter, though `PLAN.md` requires one.
  *(VS-026, G5, M7, M11, #47, #48 9)*
- **`otpauth://…?encoder=steam` is not recognised.** Only Bitwarden's
  `steam://` form routes to the Steam derivation; a seed exported from Aegis
  or KeePassXC falls through and produces a plausible six-digit code that
  will never work — a confidently wrong answer rather than a fail-closed one.
  *(S-08, found while integrating #67)*
- **1Password OTP fields are read from the field's `value`** and rendered
  through `VaultwardenTOTP.generate`. If some `op` build returns a generated
  code there rather than an `otpauth://` URI, the row reads "Unreadable
  one-time code seed". A bare 6–8-digit fallback costs nothing. *(VS-071)*
- **`lock(_:)` clears the clipboard for an unrelated vault**: copy from vault
  A, lock vault B, lose A's copy. Defensible, undocumented, surprising.
  *(#72)*
- **CLI rows never offer "Copy One-Time Code"** even after their secrets are
  fetched, because the row menu reads `hasOneTimeCode` from the projection,
  which is false for both CLI providers by construction. The detail view
  offers the copy; the row could too once hydration is cheap to ask about.
  *(S-09)*
- **`AppModel.unlockError` is dead UI state** — written and cleared by every
  unlock path, read by no view (the locked-vault pane renders
  `VaultSlot.state.failed`). One surface should go. *(S-01)*
- **TOTP countdown shows a stale-looking "1s" at the boundary** (ceiling
  round); cosmetic, but the kind of detail users read as a wrong code.
  *(B5)*

## 3. Performance

Measure on hardware before acting; none of this has been profiled on a Mac.

- **Post-sync projection rebuild decrypts every cipher synchronously** inside
  the main-actor `mutate`. Compute projections off-actor and swap in. The
  merged content-unchanged skip avoids the common case, not the real one.
  *(VS-021, #66 P3, #48 21)*
- **There are two search implementations.** The expensive half is now shared:
  both read `ItemSearchRow`, so the browser's filter no longer runs an ICU
  collation per field per item per keystroke over a haystack array it
  allocated on the spot, and both fold case the same way. The browser's query
  is debounced and its result cached on `AppModel` rather than recomputed per
  body pass. What remains open is the *ranked* half — the list still orders
  alphabetically while searching, deliberately, because reordering rows under
  a user who is typing is a product change and not a fix for the cost.
  *(S-04, #72, VS-019/028/033, M11)*
- **A large list diff is superlinear, and typing the first filter character is
  the largest diff there is.** A user-supplied `sample` of a one-minute hang
  (macOS 26.6.1, `0.1.0`) put every main-thread sample inside one
  `NSTableView.endUpdates` under `OutlineListCoordinator.diffRows`: removing
  each row view deregisters nine notification observers and three KVO
  observations, and rebuilds a `PreferenceBridge` entry list by linear scan —
  each a scan of a registry sized by the rows still alive. Debouncing turns a
  typing burst into one such pass and keeping the `List` mounted across the
  empty state stops the worst one, but the single whole-vault-to-few-matches
  diff is unchanged. If it is still slow on a large vault, the next lever is a
  rendered-row cap like Quick Search's `maximumResults`, which is a product
  decision about whether a browser may refuse to scroll its whole corpus.
  *(new; found by measurement, not review)*
- **`QuickSearchPanelModel.present` maps the whole open corpus into `Row`s on
  the main actor when the panel opens** — a launch stall for the panel on a
  very large vault. Build rows off-actor. *(S-05-adjacent)*
- **No revision-gated or no-change sync path**: every sync re-downloads, and
  the whole sealed snapshot file is re-encrypted and rewritten even when
  nothing changed (the merged skip only avoids the in-memory decrypt). CLI
  providers run one child process per vault per refresh. *(VS-022, #48 22)*
- **Both CLI providers re-probe the CLI version (`--version`) before every
  on-demand secret fetch.** *(VS-066, #47)*
- **Favicon bytes are accumulated one byte at a time** through the
  `AsyncBytes` drain. *(#47, #48 28/29)*
- **PBKDF2 unlock runs off-main (correct) but occupies a cooperative
  thread.** *(#48 32)*
- **Performance fixtures measure presentation, not the corpus path.** Add
  release-mode generated corpora and signposts around normalization, ranking,
  publication and row render. *(VS-047, #48 31)*
- **Whole-file caches amplify memory and write cost**; a 128 MiB sealed file
  means peak memory several multiples of it. *(VS-024)*

## 4. Product gaps

**Browse and retrieve**

- An Archived / Trash view with restore and unarchive. *(G5, M7, VS-026)*
- A Favorites filter or pinned section — the star badge landed, the scope did
  not. *(G6, M6, VS-027)*
- Sort options: recently used, modified, folder, type. Needs `revisionDate`
  on projections. *(G7, M8, VS-028)*
- A category filter — logins, cards, notes, identities. *(#66 M9)*
- Recently used / recently viewed, feeding both the list and Quick Search's
  empty state. *(M12, N9, #72)*
- Search qualifiers: `type:card`, `fav:`, `vault:Work`. *(M13)*
- Fuzzy or subsequence matching with ranking and typo tolerance.
  *(M11, VS-028)*
- Multi-select and bulk actions. *(#72)*
- Item metadata — created and modified dates, and password history, both of
  which the cipher model already carries and nothing displays.
  *(#66 M10, #72)*

**Create and edit**

- Create and edit beyond logins: secure notes at minimum, then cards and
  identities. *(G3, #48, #66 M12)*
- Custom-field editing. *(G4, ds-F10)*
- A folder picker on create and edit; folders are read-only today.
  *(ds-F9, #72)*
- Duplicate detection and save-time URI normalization assistance. *(#48 51)*

**Accounts and providers**

- Account removal, rename, reorder, reconnect, diagnostics, cache age and
  size, per-account lock settings. *(G1, VS-030, #48 15)*
- Multiple Vaultwarden accounts. *(G2, M8, #66 M13)*
- Honest offline and stale state: distinguish offline, stale cache, session
  expired, reauthentication required, partial CLI state and never-synced.
  *(VS-031, #72)*
- Unsupported item types should get honest read-only placeholders naming the
  provider and version, not a generic "Item". *(VS-034, #48 17)*

**Platform**

- A menu-bar extra: search, copy a one-time code, lock, without raising the
  window. *(M5, N11, #66 M15, #48 52, #72)*
- "Open at login" — `SMAppService.mainApp` is an Apple framework, not a
  third-party dependency, so it needs no adoption gate, and it is one of the
  first settings a password-manager user looks for. *(S-10)*
- A local vault-health view: reused, weak, short and old passwords, and
  logins with no one-time code. Entirely local, works across all three
  providers; the generator's strength estimator is the piece it needs.
  *(G13, M18, VS-048, #72)*
- Argon2id unlock — fails closed correctly today; gated by
  `docs/dependencies/argon2.md`. *(VS-013, #66 M14)*
- Passkeys, attachments, SSH-key items, AutoFill, Safari extension, import
  and export, Sends. Deferred by `ARCHITECTURE.md`'s non-goals; listed so the
  absence is a decision rather than an oversight. *(M9, M10, VS-035, #66
  M19–M21)*
- Apple Watch unlock — `LAPolicy.deviceOwnerAuthentication` already covers
  it; low effort. *(M16)*
- Export of non-secret metadata for auditing, or an explicit "no export by
  design" line in Settings. *(#72)*
- Delete and trash for Vaultwarden, which offers archive only. *(#72)*
- A clipboard-expiry preference — `ClipboardService` documents that a shorter
  expiry "may be layered on later"; Settings has no entry for one of the
  app's headline protections. *(S-11)*

## 5. Interaction and keyboard

- Return opens detail, ⌘Return opens the website, ⌘C copies the username,
  from the list; Return and Space currently do nothing there. (List copy
  shortcuts must be disambiguated against the detail pane's existing hidden
  ⌘⇧C/⌘⌥C buttons, which are present whenever a detail is shown.) *(U3, #72)*
- ⌘F to focus search — focusing a `.searchable` field programmatically needs
  `searchFocused`, macOS 15+; on 14 it needs a different search field. *(#72)*
- Type-to-find in the item list: focus the list, start typing, filter
  immediately, the way Finder behaves. *(#72)*
- A reveal-all toggle for items with many concealed fields, such as cards and
  identities. *(U5)*
- Copy by clicking the value text, not only the icon button. *(U6)*
- A visible "Synced" confirmation after a manual sync, beyond the spinner.
  *(U8)*
- Hold-to-reveal: press and hold while a secret field is focused, release to
  conceal, with click-reveal kept as the accessibility alternative.
  *(#52, #72)*
- Restore the last-selected scope on launch. Window restoration is
  deliberately off for secret-bearing state, but the scope is not secret.
  *(#72)*
- Drag and drop a username or password into another app — one of the few ways
  to fill a field without an extension; it would go through `ClipboardService`
  so the expiry survives. *(G14, N10, #72)*
- A "code sent" confirmation and cooldown on the emailed 2FA challenge; today
  `Send Code` disables only while in flight. *(#47)*
- 1Password's "Open" is not the default action while Proton's is, so Return
  does nothing in that pane. *(#72)*
- Declining an origin or KDF approval bounces to the generic sign-in-failed
  screen rather than framing "you declined X". *(#47)*
- Wrong-password feedback: a subtle shake, a haptic, and field refocus.
  *(#66 U3)*
- A retry affordance on failed vault rows, and `.help()` tooltips on sidebar
  failure rows, whose messages truncate to one line today. *(#66 U8, U9)*
- Empty and error states should offer the next action — Unlock Vault, Open
  All Available, Clear Search, Retry Sync, Show Supported CLI Setup, Learn
  Why This Is Read-only. *(VS-042, #48 42)*
- ⌘⌥C (copy username in the detail) silently does nothing when the username
  field isn't literally labelled "Username" (custom-label imports). Fall back
  to the first plain field, or disable the shortcut honestly. *(S-12)*

## 6. Visual design and layout

- **Two visual personalities.** The empty shell's identity rail — gradient,
  tracked small caps, shield — is the only art direction in the app and
  appears only before the first account exists. Its vocabulary should carry
  into the locked pane, the empty detail, and the Quick Search header.
  *(VS-037, G12, V1, #48 33, #47, #72)*
- **Detail is a flat field-and-divider list.** Group fields into rounded,
  material-backed cards like macOS Settings — the single biggest visual
  upgrade for the risk. *(V3, A1, VS-040, #48 35)*
- **Detail labels are uppercase and heavy.** Sentence case at subheadline
  weight reads modern; reserve caps for metadata. *(V2)*
- **Detail header is unbalanced** — a 46 pt icon against a `.largeTitle`.
  Enlarge the icon or step the title down; a rounded background would make it
  read as a tile. *(V4)*
- **Monospaced, grouped secrets**: group passwords in four-character runs
  with subtle colouring for digits and symbols, which is how people read a
  password aloud. *(#72)*
- **The toolbar status item fights the toolbar** — a bare relative timestamp
  wrapped in `fixedSize` and manual padding whose own comment explains it is
  compensating for the toolbar capsule. A purpose-built status pill with a
  leading symbol and the word "Synced" would stop needing the hack.
  *(V7, A7, #72)*
- **The item row truncates the username** because the vault badge shares its
  line and wins the space contest on a narrow window. There is also no
  density option. *(#72)*
- **The locked-vault pane is a left-aligned wall** in a wide empty pane.
  Centred in a card with the provider's mark it would read as designed. *(#72)*
- **Fixed sizes clip at larger text**: Add Account at 420 pt wide with no
  outer scroll and a 1Password account list that can grow past the screen;
  the edit sheet pinned at 460 × 560 with 54 pt and 70 pt text editors.
  *(VS-036, V10, #47, #72; the Settings half was fixed by #79)*
- **Fixed 120 pt label columns** in the KDF-change and origin-approval panels
  risk clipping under Dynamic Type. *(#47)*
- **The default window is cramped** for a three-column password manager.
  *(#48 34; partially addressed by #79's column floors)*
- **The toolbar is crowded and weakly contextual** — Add, Edit, Archive, Sync
  and Lock All as equal-weight items, mostly disabled. Keep Add and Sync
  primary, move item actions to the detail and context menus, keep Lock
  distinct. *(VS-039, #48 37)*
- **Errors are embedded in sidebar subtitles**; use a status badge plus a
  details affordance. *(#48 43)*
- **Disclosure and lock controls have small click targets.** *(V8, #48 44)*
- **The site-icon privacy toggle is admirable but verbose**; lead with one
  line. *(#48 45)*
- **Primary actions never use `.borderedProminent`**, relying on
  `.keyboardShortcut(.defaultAction)` alone for hierarchy. *(#47)*
- **No transitions between Add Account's phases** (form → 2FA → approval →
  success). *(#47)*
- **Spacing varies** across 28/24/22/20/14/12/8; adopt a documented
  4/8/12/16/24/32 scale. *(A4)*
- **Typography mixes** `.largeTitle`, `.title2`, `.system(size: 34)` and
  `.system(.title3, design: .rounded)` across four screens. Pick one scale.
  *(#72)*
- **The palette is minimal** — accent plus secondary greys. Per-category icon
  tints, a brand-tinted locked shell and restrained gradients would lift
  perceived value without losing the serious tone. *(V13, A5, #66 A3)*
- **One accent per provider** for the sidebar icon, locked pane and
  merged-list badge — one dictionary, and merged lists become scannable.
  *(N2, V11, #66 A4, #47, #72)*
- **Materials, not flat panes**: the sidebar should use `.sidebar` style with
  a material background and the detail a subtly elevated surface, the way the
  Quick Search panel already does. *(#72, #66 A5)*
- **Motion.** There is one animation in the app, the sidebar twisty. A vault
  opening, fields appearing, and the lock closing all deserve a short snappy
  transition — the lock is the emotional beat of a password manager and it
  currently happens invisibly. A proper locked treatment would blur the
  content behind a material rather than swap layouts. *(A3, #66 A1, #72)*
- **Selection and hover refinement** in lists: an accent-tinted leading edge
  or soft fill, and a quiet hover affordance. *(A8)*
- **The app icon is too detailed for small sizes** — fine bolts, reflections,
  chainmail and multiple keyholes lose their silhouette at 16–32 px. The
  small-size review gate is already recorded as open; commission reviewed
  optical variants under the provenance process rather than replacing the
  canonical art. *(VS-038)*
- **A witty empty state for a freshly created, item-less vault** — the code
  comments already have an established editorial voice. *(#47)*

## 7. Accessibility

- **Monogram colours are not contrast-safe.** A fixed HSB brightness over an
  18% tint of the same hue means yellow and green regions of the hue range
  can be permanently hard to read, with no colourblind differentiator. Derive
  separate light and dark tones against a minimum contrast target, add a
  colour-math test over all hue buckets, and validate increased-contrast
  mode. *(VS-054, #47)*
- **Unlock and error focus are not keyboard-first.** The `.allVaults` default
  makes a sole Vaultwarden password field require a sidebar click first, the
  field has no `@FocusState`, and errors are red text with no focus movement,
  announcement, or non-colour symbol. *(VS-053)*
- **Status relies on subtle colour and tiny secondary text.** Every status
  needs icon plus text, adequate contrast, and a discoverable details action.
  *(VS-041)*
- **No reduced-motion, increased-contrast, Dynamic Type or localization
  review has been done.** *(#48 46)*
- **Never put a secret into feedback or accessibility text.** *(VS-040)*

## 8. Governance, claims, and testing

- **The README overstates readiness.** It says providers and writes are
  implemented end to end, offline cache is usable, archive works and multiple
  vaults operate, while `RELEASE_ELIGIBILITY.md` says no release evidence set
  exists. Split the status into "code present", "fake-boundary tested",
  "live-contract tested" and "release admitted". Never label a capability
  supported because code exists. *(VS-044, #33 1, #48 1)*
- **Workstream status is stale and contradictory** across `DELIVERY.md`, the
  workstream records and the README. One machine-readable feature and
  evidence manifest should drive the README tables, release gating and UI
  capability admission. *(VS-045)*
- **The flat AEAD cache is not the planned encrypted database.**
  `EncryptedStore` is a protocol and a test double; there are no row-level
  updates and no WAL, migration or crash evidence. Workstream 5 is not done.
  *(VS-014, #48 14)*
- **UI coverage stops near the shell.** No coverage of successful login or
  2FA, unlock, list and detail, reveal and copy, create/edit conflict,
  archive, per-vault lock, search navigation, large text, or error focus.
  *(VS-046)*
- Process notes carry forward: read the open pull request list before
  starting; do not bundle visual redesign, new item types, or product surface
  into a security fix; record the clean-room attestation per document.

## 9. Ideas worth stealing

Concepts, not commitments. Several touch security controls and are marked.

- **Screenshot shyness.** While a secret is revealed, set the window's
  `sharingType` to `.none` so screen recordings and screenshots capture a
  blank pane. One line, and the kind of thing users tell each other about.
  *(D1, #72, #48 4)*
- **The Squire.** The app has a name and a heraldic shield and does nothing
  with either. A mark that latches shut on lock — one 200 ms animation —
  would give it a signature moment. Quiet, not cute. *(#72, #47)*
- **Clipboard countdown in the menu bar.** While a copied secret is live, a
  tiny draining ring; click to clear immediately. Makes the app's best-hidden
  security property its most visible one. *(#72, #52, #48 10)*
- **A command palette.** ⌘⇧P for app actions — Lock, Sync, Add Item, Generate
  Password, Toggle Site Icons, Settings. Quick Search could recognise
  `>`-prefixed verbs instead, without sending queries anywhere. *(N3, #52)*
- **Vault weather.** One line in the sidebar footer: "3 reused · 1 weak ·
  synced 2 min ago". Local, honest, and a reason to open the app when you do
  not need a password. *(#72, #52)*
- **Peek with Space.** Select a row, tap Space, get a floating card with the
  username and a copy button without leaving the list. *(#72)*
- **Provider parity table in Settings.** A grid of which actions each
  connected provider supports and why the others are absent; the capability
  model already knows the answer. *(#72, #52, #48 6)*
- **Privacy receipt.** A local, ephemeral panel listing what VaultSquire
  contacted this session by category and count only — "your server: 3
  requests; provider CLI: 2 runs; site icons: 0" — with no domains and nothing
  persisted. *(#52)*
- **Provider truth badges**: `Offline snapshot • 2h old`, `Read-only via CLI`,
  `Reauthentication needed` — makes provider asymmetry feel intentional.
  *(#52)*
- **Memorable and pronounceable generation** with a live entropy readout and
  a "time to crack" line under generated passwords. *(N5, #66 D4, #48 9)*
- **TOTP import from a QR image** — drop or paste a screenshot and decode the
  `otpauth://` seed. *(N6)*
- **Next-code preview** in the last five seconds of a TOTP window. *(#66 D6)*
- **In-app "recently copied"** — a tiny ephemeral in-memory list of the last
  few copied fields, cleared on lock like everything else. *(N7)*
- **A vault-open window accent** — a barely-there rule or dot while anything
  is unlocked, gone entirely when locked. *(N8)*
- **Recents when empty in Quick Search**, instead of the whole vault
  alphabetically in a 330-point panel. *(N9)*
- **Travel lock** — an intentionally stronger temporary posture that disables
  Touch ID. *(#48 7)*
- **Polite shoulder-surfing mode** — one click hides everything sensitive.
  *(#48 4)*
- **Vault Constellation** — an optional overview of each open vault as a
  tasteful graphic. *(#48 2)*
- **"Archived — tucked away, not deleted"** as the framing once an Archived
  view ships. *(#47)*
- **Copy diagnostic details on CLI failure** — a copyable diagnostic block to
  help users file detection bugs. *(#47)*
- **Haptics on lock and unlock**, and a quiet checkmark the first time Touch
  ID is set up. *(#66 D3, N12)*
- **A teachable-moment toast** after an inactivity auto-lock. *(#66 D7)*
- **Password-age nudge** on the detail pane. *(#66 D5)*
- **Breach checking**, if ever wanted, only as a k-anonymity SHA-1 prefix
  range query — opt-in, off by default. **Needs policy.** *(N4, #66 M17)*
- **Live TOTP in the list row.** The seed is deliberately not on the
  projection; a safer cousin is a per-row "has TOTP" dot with hover-copy that
  hydrates transiently. **Needs design.** *(N1)*
- **Category chips above the list** (All / Logins / Cards / Notes /
  Identities) — cheap, scannable, and works with the merged All-Vaults scope.
  *(S-13)*
- **An unlock ceremony.** The first unlock after installation could end on a
  one-line summary ("142 items · synced 2 min ago · Touch ID ready") — a
  micro-onboarding that teaches the app's language. *(S-14)*
- **Show the clipboard countdown where the copy happened** — the detail pane
  does; the row context menu and Quick Search could too. *(S-15)*

## 10. What is good, and must not regress

- The security posture is coherent and documented: generation-based
  discarding of late results, clipboard ownership gated on the change count,
  fail-closed CLI version gates, no-argv/no-environment secret handling, and
  the "site's own origin, never an aggregator" icon rule.
- Capability gating is real, enforced in the use-case layer rather than by
  disabling a button.
- Per-vault independent sessions with a merged All Vaults scope is the right
  model and is well implemented.
- The provider boundary is real rather than aspirational.
- TOTP is correct against RFC 6238 and 4226, including Base32, multiple
  algorithms, digit counts and periods.
- Deterministic monogram tiles with a written-out FNV-1a hash are a smart,
  privacy-respecting default.
- The comments record why, including past traps, at a level most codebases
  never reach.
- The test surface is broad — roughly 12k lines including leakage, fuzz,
  cancellation and capability tests.
- `Vaultwarden.unlock()` reads the local sealed cache first, so the vault
  opens without waiting on the network; CLI providers now fall back to sealed
  snapshots on genuine outage without treating a provider refusal as an
  outage.
- `AutoLockController` is a complete and correct inactivity lock; every gap
  reported against it was in Settings, not the policy engine.

## 11. Definition of done

An item leaves this backlog when its pull request is merged **and** all
applicable positive, negative, cancellation, ambiguity, leakage,
accessibility and performance evidence is linked. "Code exists", "a unit test
over a fake passed", and "an open PR is green" are not synonymous with
supported or done.
