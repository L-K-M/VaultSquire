# VaultSquire consolidated backlog — 2026-08-12

Eight pull requests each proposed adding a review document to this repository.
Seven of them added a file called `ANALYSIS.md`, so they conflicted with one
another by construction, and five also added a per-pass file at the repository
root named after the model that wrote it (`sol.md`, `opus.md`, `ds.md`,
`k3.md`, `glm.md`) — with `opus.md` claimed twice, by two different documents.

This is those fourteen files merged into one. Every distinct idea from all of
them is here: security findings, correctness bugs, performance work, product
gaps, interaction and visual notes, accessibility, governance, and the
speculative "delight" ideas each reviewer ended on. Where several reviewers
found the same thing the entry is merged and cites each of them, so no
reviewer's phrasing of a shared finding is lost.

- Merged from: #33, #37, #47, #48, #52, #66, #69, #72
- Review base for all eight: `0c05294`
- Companion: [`2026-08-12-open-pr-consolidation.md`](2026-08-12-open-pr-consolidation.md)
  records which pull requests were taken and why, and why #30 must not be
  merged as a branch.

**On the "Done" tables in the source documents.** Every one of the eight marked
work as done that was only ever an open pull request against the same base.
Nothing in them was merged. The status below was re-derived from the code, not
copied from those tables.

Origins are given as the reviewer's own identifier where one exists — `VS-006`
(#52), `B7` (#66/#69), `G8`/`M1`/`V6`/`N3` (#69), `R2` (the merged adversarial
review), `ds-B11` (#48), and so on — so a reader can trace any entry back.

---

## 1. Closed by the consolidation

Recorded so they are not raised again. See the companion document for which
branch each came from.

| Finding | Origins |
|---|---|
| Revealed secrets were text-selectable, so ⌘C bypassed `ClipboardService` | VS-006, #48 S1 |
| Quick Search kept decrypted projections after dismiss and after lock | VS-051, B7, B8 |
| A partial CLI refresh replaced the last complete sealed snapshot | VS-007, R7, #48 6 |
| The whole vault was decrypted twice on every unlock | #47 opus §1.1 |
| CLI on-demand secrets survived a sync, showing a rotated password as fresh | VS-055 |
| A per-vault lock left that vault's site icons in the shared store | VS-056, #48 13 |
| The Quick Search hand-off lost or hid the chosen item | VS-057, #48 12, B3, B4 |
| Closing the main window stranded the running app | VS-058, ds-19 |
| Auto-lock could fire up to 7.5 minutes late at the default timeout | B1 |
| A typed-but-unsubmitted master password lingered for the process lifetime | B2 |
| A write completing after a lock republished into the closed vault | VS-005 |
| `unlock(_:password:)` lacked the already-open guard biometrics had | #47 |
| The editor closed on any write finishing, discarding the draft | B7, B11 |
| A stale write error greeted the next editor sheet | #66 B3 |
| Archive was one click, silent, with no in-app way back | #47, ds-20 |
| Settings denied that a lock policy existed while one was running | VS-043, G11, #48 40 |
| The inactivity timeout could only be changed with `defaults write` | VS-043, G11 |
| No password generator | VS-029, G8, M1, #48 47 |
| No row context menu or row copy actions | VS-028, G9, U1, #47 |
| Quick Search had no keyboard navigation, ranking, or vault attribution | VS-033, M3, #48 38 |
| No copy confirmation or clipboard countdown | U7, VS-040, #48 36 |
| The TOTP row had no progress affordance | V5, A2, A6 |
| A revealed secret stayed on screen until lock | U4, VS-040 |
| No empty state when a filter matched nothing | V12, #48 26 |
| Favourites were collected and never shown | VS-027, G6, M5, M6, #48 10, #72 |
| `AppModel.items` and `VaultSlot.groups` recomputed on every access | VS-020, P1, P2, P5, #47 |
| Site icons published one at a time, invalidating every row | #65 |
| CLI hydration had no visible loading state | VS-052 |
| The URI confirmation named only the host, not the address handed over | VS-017 |
| Digit grouping only applied to six-digit codes | B6 |
| 2FA "Back" did not cancel the in-flight verification | VS-061, #47 |
| Steam Guard (`steam://`) seeds were unreadable | #47 |
| A Task was allocated per input event, including every `.mouseMoved` | VS-023, #47 |

---

## 2. Security and trust

### Still unenforced controls

- **Master-password reprompt is not enforced.** `requiresReprompt` is preserved
  on the wire model, but reveal, copy, edit and archive never ask for fresh
  authentication; quick unlock or an already-open session satisfies them. Add
  negative tests for every action path. *(VS-011, R2, #48 2, #72)*
- **Key-rotation reauthentication is incomplete.** #29 stopped sync from
  absorbing rotated key material, which is the safe half. The rest — detect the
  rotation, persist `reauthenticationRequired`, retain the prior complete
  snapshot, invalidate quick unlock, refuse secret operations, and clear only on
  a complete reauth — does not exist, and the next unlock can misleadingly
  report a bad password. Implement only as one transaction with crash and
  cancellation tests. *(VS-004, R1, #48 3)*
- **CLI cache-envelope keys are not bound to user presence.** They use an
  ordinary device-only Keychain item. The snapshots omit secret values but
  disclose account inventory, titles, usernames, addresses and vault names.
  *(VS-010, R3, #48 4)*
- **CLI executable identity rests on path and self-reported version.** A
  replaced `pass-cli` or `op` at an allowlisted path can claim an admitted
  version. Require code signature, team identity, designated requirement and
  notarization assessment of the resolved executable, persist the approved
  identity, and detect replacement. *(VS-009, R4, #48 5)*
- **Per-item reprompt is preserved on write and ignored on read.** *(#72)*

### Secret exposure

- **CLI stdout and stderr queues are not bounded**, despite the documented
  bounded I/O. Both `AsyncStream`s are created with
  `bufferingPolicy: .unbounded`; stdout is capped only once chunks reach the
  collector and stderr has no byte cap at all. A replaced CLI can enqueue faster
  than the actor drains. *(VS-008 — unique to #52)*
- **Accessibility identifiers embed vault content** — `reveal-\(field.label)`
  and `open-uri-\(field.label)`, where the label can be a user's custom-field
  name, so vault-derived strings enter the accessibility tree and any UI test
  keyed on them. *(VS-067 — unique to #72)*
- **`.mouseMoved` counts as activity for the inactivity clock.** With the app
  frontmost and the pointer over the window, ambient motion defeats auto-lock
  indefinitely. Keystrokes, clicks and scrolls are the honest signals. This is a
  security decision, not only the performance one it resembles. *(#72, VS-023)*
- **Site-icon fetches follow redirects with a default delegate**, so a site can
  redirect its favicon to an aggregator or tracker — contradicting the README's
  promise that no icon service is ever involved. Decoding also runs on the main
  actor, and a file under the 256 KiB cap can still carry ruinous dimensions.
  *(VS-016)*
- **`lock(_:)` clears the clipboard for an unrelated vault**: copy from vault A,
  lock vault B, lose A's copy. Defensible, undocumented, surprising. *(#72)*

### Security state that is not surfaced

- **`sessionExpired` is displayed as an error, not a state transition.** A
  revoked refresh token leaves the decrypted vault open on screen and permits
  repeated doomed operations. *(VS-049)*
- **Local persistence failures are reported as network success.** A failed
  rotated refresh-token replacement and a failed `vaultCache.save` are both
  ignored while the fresh snapshot returns as success, so the UI shows data that
  was never durably sealed. *(VS-050)*
- **Initial sign-in reports success without a complete first snapshot.**
  `persistAfterLogin` seeds an empty snapshot best-effort, so a first unlock can
  present an empty vault under "Account Added". *(VS-003)*
- **No secure logout or account-removal transaction.**
  `AccountDescriptorStore.remove` exists and is dead code; nothing deletes
  tokens, descriptors, cache files, biometric envelopes or CLI cache keys.
  *(VS-012, G1, #48 15, R-adjacent)*

### Capability admission

- **Untested CLI releases sit in the production allowlists** — Proton admits
  2.2.3–2.2.6 and 1Password five stable releases, with in-code comments saying
  none was exercised against a live CLI. Empty is the safe pre-evidence state.
  *(VS-001)*
- **Vaultwarden create/update/archive are exposed before their conflict,
  ambiguity, leakage and official-client evidence exists.** *(VS-002)*
- **Real-provider compatibility is unproven.** Both CLI mappings are tested only
  through fake executors, the 1Password GUI-without-a-TTY authorization path is
  unresolved, and the Vaultwarden cross-client crypto differential is
  outstanding. *(#33 7, #48 7)*

---

## 3. Correctness

- **Vaultwarden `collections` are never decoded.** `VaultwardenSyncResponse`
  decodes profile, folders and ciphers only; a cipher's `collectionIds` is
  preserved for write pass-through and nothing else. An organization item filed
  only under a collection gets empty `groupingLabels` and is invisible to
  sidebar grouping and collection search, though `PLAN.md` lists collections as
  in scope for the read preview. *(#47 — unique)*
- **`openCredentialFreeVaults()` overrides a deliberate lock.** It runs on every
  successful unlock, so a CLI vault the user locked on purpose is reopened by an
  unrelated Vaultwarden unlock. Open only credential-free vaults not explicitly
  locked this session. *(VS-068 — unique to #72)*
- **A second Vaultwarden account silently replaces the first.** Credentials are
  keyed to `AccountID.vaultwardenPrimary` and the add-account form offers itself
  again with no warning that it will overwrite. *(G2, M8, #48 16, #72)*
- **A second submit is dropped in silence.** `save(_:to:)` opens with
  `guard !isWriting else { return }` — no feedback and no queue. Narrow, because
  the button is disabled, but the guard should not be the only answer. *(#72)*
- **Quick Search does not see a sync.** Locking a vault now refreshes an open
  panel; a sync landing while it is up is still invisible.
  `ApplicationCoordinator.refreshQuickSearch()` needs one more caller on the
  sync-completion path. *(B8, VS-051-adjacent, #72)*
- **`SiteIconStore` marks a host attempted before the await**, so one transient
  failure disables that icon for the rest of the session; and it has **no
  eviction at its 500-icon cap**, so once full no new host ever loads. *(B9,
  #66 B8)*
- **Empty Proton and 1Password vaults never appear in the sidebar.**
  Vaultwarden folders are seeded from `folderNames`, but CLI-provider groups are
  derived from items alone. *(ds-B11)*
- **Vault count is silently capped at 50** for both CLI providers, with no
  error, count, or "and N more" anywhere. *(#47)*
- **Transport failure claims the change was not saved**, but a connection can
  fail after the server commits. Distinguish pre-send from ambiguous failure,
  keep the draft, and block retry pending an authoritative read. *(VS-018,
  #48 11)*
- **`VaultSession`/`SessionState` is a fully tested state machine production
  code does not use.** This is why session expiry, reauthentication and durable
  rotation are "implemented" only in an unused abstraction. Wire it in as the
  single authority or delete it and move its invariants to the live model.
  *(VS-059, ds-21)*
- **`VaultItemProjection` whole-value equality trap.** Selection is keyed by
  `id` today; anything keying on the whole value breaks across syncs. Worth a
  code comment. *(#66 B12)*
- **1Password OTP fields are read from the field's `value`** and rendered
  through `VaultwardenTOTP.generate`. If some `op` build returns a generated
  code there rather than an `otpauth://` URI, the row reads "Unreadable one-time
  code seed". Unverified; a fallback that shows a bare 6–8 digit value as a code
  costs nothing. *(VS-071 — unique to #72)*
- **`otpauth://…?encoder=steam` is not recognised.** Only Bitwarden's
  `steam://` form routes to the Steam derivation; a seed exported from Aegis or
  KeePassXC falls through and produces a plausible six-digit code that will
  never work. That is a confidently wrong answer rather than a fail-closed one.
  *(found while integrating #67)*
- **TOTP countdown uses a ceiling round** and can show a confusing "1s" at the
  boundary. *(B5)*
- **`NSApp.activate()` may not raise the app** for Quick Search on recent macOS;
  consider `activate(ignoringOtherApps:)` after interactive testing. *(#66 B10)*
- **Archived and trashed items cannot be browsed or restored.** Archiving now
  confirms and says where to restore from, but `restoreItem` is unused and there
  is no Archived or Trash filter, though `PLAN.md` requires one. *(VS-026, G5,
  M7, M11, #47, #48 9)*

---

## 4. Performance

Measure on hardware before acting; none of this has been profiled on a Mac.

- **`detail(for:)` is called from the view body**, linearly scans the cipher
  array and runs an AES-CBC decrypt plus HMAC verify per field on every
  invocation — re-run by any `AppModel` publish. Memoise on item id, snapshot
  generation and hydration state. *(#72 P4, #66 P4)*
- **Post-sync projection rebuild decrypts every cipher synchronously** inside
  the main-actor `mutate`. Compute projections off-actor and swap in. Most
  likely user-visible stall on a large vault. *(VS-021, #66 P3, #48 21)*
- **There are two search implementations.** Quick Search ranks; the browser
  still uses the original substring `matches`, building a haystack array per
  item per keystroke. They should be one matcher — ideally the ranked one, so
  the list orders by relevance while searching and by title otherwise. *(#72,
  VS-019/028/033, M11)*
- **No debounce or cancellation on either search.** *(P3, P4 in #69, VS-019)*
- **No revision-gated or no-change sync path**: every sync re-downloads,
  re-decrypts and rewrites the whole sealed file, and CLI providers run one
  process per vault per refresh. *(VS-022, #48 22)*
- **Both CLI providers re-probe the CLI version before every on-demand secret
  fetch.** *(VS-066, #47)*
- **No in-flight concurrency limit on favicon fetches**; fast scrolling through
  a vault with many hosts can burst dozens of concurrent requests, and icon
  bytes are accumulated one byte at a time. *(VS-024, #47, #48 28/29)*
- **The TOTP timeline recomputes the full HMAC once a second** when the code
  changes once a period. Split the countdown from the code so only the countdown
  ticks. *(VS-025, #72, #69 P5)*
- **Whole-file caches amplify memory and write cost**; a 128 MiB sealed file
  means peak memory several multiples of it. *(VS-024)*
- **PBKDF2 unlock runs off-main (correct) but occupies a cooperative thread.**
  *(#48 32)*
- **Performance fixtures measure presentation, not the corpus path.** The Quick
  Search fixture does not prove query, index and render at 10k/100k. Add
  release-mode generated corpora and signposts around normalization, ranking,
  publication and row render. *(VS-047, #48 31)*

---

## 5. Product gaps

Ordered roughly by value within each group.

**Browse and retrieve**

- An Archived / Trash view with restore and unarchive. *(G5, M7, VS-026)*
- A Favorites filter or pinned section — the star badge landed, the scope did
  not. *(G6, M6, VS-027)*
- Sort options: recently used, modified, folder, type. Needs `revisionDate` on
  projections. *(G7, M8, VS-028)*
- A category filter — logins, cards, notes, identities. *(#66 M9)*
- Recently used / recently viewed, feeding both the list and Quick Search's
  empty state. *(M12, N9, #72)*
- Search qualifiers: `type:card`, `fav:`, `vault:Work`. *(M13)*
- Fuzzy or subsequence matching with ranking and typo tolerance. *(M11, VS-028)*
- Multi-select and bulk actions. *(#72)*
- Item metadata — created and modified dates, and password history, both of
  which the cipher model already carries and nothing displays. *(#66 M10, #72)*

**Create and edit**

- Create and edit beyond logins: secure notes at minimum, then cards and
  identities. *(G3, VS-050 in #48, #66 M12)*
- Custom-field editing. *(G4, ds-F10)*
- A folder picker on create and edit; folders are read-only today. *(ds-F9,
  #72)*
- Duplicate detection and save-time URI normalization assistance. *(#48 51)*

**Accounts and providers**

- Account removal, rename, reorder, reconnect, diagnostics, cache age and size,
  per-account lock settings. *(G1, VS-030, #48 15)*
- Multiple Vaultwarden accounts. *(G2, M8, #66 M13)*
- Honest offline and stale state: distinguish offline, stale cache, session
  expired, reauthentication required, partial CLI state and never-synced.
  *(VS-031, #72)*
- Unsupported item types should get honest read-only placeholders naming the
  provider and version, not a generic "Item". *(VS-034, #48 17)*

**Platform**

- A global, system-wide Quick Search hotkey. The current shortcut is an app menu
  shortcut, active only while VaultSquire is frontmost, while Settings presents
  it as a value. Gated by `docs/dependencies/keyboard-shortcuts.md`. *(M2, B10,
  VS-032, #66 M1)*
- A menu-bar extra: search, copy a one-time code, lock, without raising the
  window. *(M5, N11, #66 M15, #48 52, #72)*
- A local vault-health view: reused, weak, short and old passwords, and logins
  with no one-time code. Entirely local, works across all three providers, and
  is the kind of feature that justifies a native client. The strength estimator
  from the generator is the piece it needs. *(G13, M18, VS-048 in #48, #72)*
- Argon2id unlock — fails closed correctly today; gated by
  `docs/dependencies/argon2.md`. *(VS-013, #66 M14)*
- Passkeys, attachments, SSH-key items, AutoFill, Safari extension, import and
  export, Sends. Deferred by `ARCHITECTURE.md`'s non-goals; listed so the
  absence is a decision rather than an oversight. *(M9, M10, VS-035, #66
  M19/M20/M21)*
- Apple Watch unlock — `LAPolicy.deviceOwnerAuthentication` already covers it
  and it is low effort. *(M16)*
- Export of non-secret metadata for auditing, or an explicit "no export by
  design" line in Settings. *(#72)*
- Delete and trash for Vaultwarden, which offers archive only. *(#72)*

---

## 6. Interaction and keyboard

- Double-click a row to open its first website; today it only selects. *(U2)*
- Return opens detail, ⌘Return opens the website, ⌘C copies the username, from
  the list. Return and Space currently do nothing there. *(U3, #72)*
- ⌘F, a shortcut for the one-time code, and a shortcut to open a website.
  Focusing a `.searchable` field programmatically needs `searchFocused`, which
  is macOS 15; on 14 it needs a different search field. *(#72)*
- Type-to-find in the item list: focus the list, start typing, filter
  immediately, no ⌘F — the way Finder behaves. *(#72)*
- "Open and copy password" as a single Quick Search action (⌘Return), and
  ⌘⇧C to copy a result's password without opening it. *(U4, D2, #47)*
- A reveal-all toggle for items with many concealed fields, such as cards and
  identities. *(U5)*
- Copy by clicking the value text, not only the icon button. *(U6)*
- A visible "Synced" confirmation after a manual sync, beyond the spinner.
  *(U8)*
- Hold-to-reveal: press and hold while a secret field is focused, release to
  conceal, with click-reveal kept as the accessibility alternative. *(#52,
  #72)*
- Restore the last-selected scope on launch. Window restoration is deliberately
  off for secret-bearing state, but the scope is not secret. *(#72)*
- Drag and drop a username or password into another app — a standard macOS
  gesture and one of the few ways to fill a field without an extension. It would
  go through `ClipboardService` so the expiry survives. *(G14, N10, #72)*
- A "code sent" confirmation and cooldown on the emailed 2FA challenge; today
  `Send Code` disables only while in flight. *(#47)*
- 1Password's "Open" is not the default action while Proton's is, so Return does
  nothing in that pane. *(#72)*
- Declining an origin or KDF approval bounces to the generic sign-in-failed
  screen rather than framing "you declined X". *(#47)*
- Wrong-password feedback: a subtle shake, a haptic, and field refocus. *(#66
  U3)*
- A retry affordance on failed vault rows, and `.help(message)` tooltips on
  sidebar failure rows, whose messages truncate to one line today. *(#66 U8,
  U9)*
- Empty and error states should offer the next action — Unlock Vault, Open All
  Available, Clear Search, Retry Sync, Show Supported CLI Setup, Learn Why This
  Is Read-only. *(VS-042, #48 42)*

---

## 7. Visual design and layout

- **Two visual personalities.** The empty shell is branded; everything after
  unlock is default AppKit chrome. The locked shell's identity rail — gradient,
  tracked small caps, shield — is the only art direction in the app and appears
  only before the first account exists. Its vocabulary should carry into the
  locked pane, the empty detail, and the Quick Search header. *(VS-037, G12,
  V1, #48 33, #47, #72)*
- **Detail is a flat field-and-divider list.** Group fields into rounded,
  material-backed cards like macOS Settings — the single biggest visual upgrade
  for the risk. *(V3, A1, VS-040, #48 35)*
- **Detail labels are uppercase and heavy.** Sentence case at subheadline weight
  reads modern; reserve caps for metadata. *(V2)*
- **Detail header is unbalanced** — a 46 pt icon against a `.largeTitle`.
  Enlarge the icon or step the title down; a rounded background would make it
  read as a tile. *(V4)*
- **The secret mask is a fixed ten bullets** regardless of length. A
  length-aware mask is more honest. *(V6)*
- **Monospaced, grouped secrets**: group passwords in four-character runs with
  subtle colouring for digits and symbols, which is how people read a password
  aloud. *(#72)*
- **The toolbar status item fights the toolbar** — a bare relative timestamp
  wrapped in `fixedSize` and manual padding whose own comment explains it is
  compensating for the toolbar capsule. A purpose-built status pill with a
  leading symbol and the word "Synced" would stop needing the hack. *(V7, A7,
  #72)*
- **The item row truncates the username** because the vault badge shares its
  line and wins the space contest on a narrow window. There is also no density
  option. *(#72)*
- **The sidebar summary reads as a fragment**: "142 items in 2 open" →
  "142 items · 2 vaults open". *(#72)*
- **The locked-vault pane is a left-aligned wall** in a wide empty pane. Centred
  in a card with the provider's mark it would read as designed. *(#72)*
- **The detail placeholder puts an item count in its description**, which is
  where a count should never live. *(#72)*
- **Fixed sizes clip at larger text**: Add Account at 420 pt wide with no outer
  scroll and a 1Password account list that can grow past the screen; the edit
  sheet pinned at 460 × 560 with 54 pt and 70 pt text editors. *(VS-036, V10,
  #47, #72)*
- **Fixed 120 pt label columns** in the KDF-change and origin-approval panels
  risk clipping under Dynamic Type. *(#47)*
- **The default window is cramped** for a three-column password manager. *(#48
  34)*
- **The toolbar is crowded and weakly contextual** — Add, Edit, Archive, Sync
  and Lock All as equal-weight items, mostly disabled. Keep Add and Sync
  primary, move item actions to the detail and context menus, keep Lock
  distinct. *(VS-039, #48 37)*
- **Errors are embedded in sidebar subtitles**; use a status badge plus a
  details affordance. *(#48 43)*
- **Disclosure and lock controls have small click targets.** *(V8, #48 44)*
- **The site-icon privacy toggle is admirable but verbose**; lead with one line.
  *(#48 45)*
- **Primary actions never use `.borderedProminent`**, relying on
  `.keyboardShortcut(.defaultAction)` alone for hierarchy. *(#47)*
- **No transitions between Add Account's phases** (form → 2FA → approval →
  success). *(#47)*
- **Spacing varies** across 28/24/22/20/14/12/8; adopt a documented 4/8/12/16/
  24/32 scale. *(A4)*
- **Typography mixes** `.largeTitle`, `.title2`, `.system(size: 34)` and
  `.system(.title3, design: .rounded)` across four screens. Pick one scale.
  *(#72)*
- **The palette is minimal** — accent plus secondary greys. Per-category icon
  tints, a brand-tinted locked shell and restrained gradients would lift
  perceived value without losing the serious tone. *(V13, A5, #66 A3)*
- **One accent per provider** for the sidebar icon, locked pane and merged-list
  badge — one dictionary, and merged lists become scannable. *(N2, V11, #66 A4,
  #47, #72)*
- **Materials, not flat panes**: the sidebar should use `.sidebar` style with a
  material background and the detail a subtly elevated surface, the way the
  Quick Search panel already does. *(#72, #66 A5)*
- **Motion.** There is one animation in the app, the sidebar twisty. A vault
  opening, fields appearing, and the lock closing all deserve a short snappy
  transition — the lock is the emotional beat of a password manager and it
  currently happens invisibly. A proper locked treatment would blur the content
  behind a material rather than swap layouts. *(A3, #66 A1, #72)*
- **Selection and hover refinement** in lists: an accent-tinted leading edge or
  soft fill, and a quiet hover affordance. *(A8)*
- **The app icon is too detailed for small sizes** — fine bolts, reflections,
  chainmail and multiple keyholes will lose their silhouette at 16–32 px. The
  small-size review gate is already recorded as open. Commission reviewed
  optical variants under the provenance process rather than replacing the
  canonical art. *(VS-038)*
- **A witty empty state for a freshly created, item-less vault** — the code
  comments already have an established editorial voice. *(#47)*

---

## 8. Accessibility

- **Copy and reveal buttons have `.help()` tooltips but no distinguishing
  `.accessibilityLabel`**, so VoiceOver likely announces every copy button
  identically. *(#47)*
- **Monogram colours are not contrast-safe.** A fixed HSB brightness over an 18%
  tint of the same hue means yellow and green regions of the hue range can be
  permanently hard to read, with no colourblind differentiator. Derive separate
  light and dark tones against a minimum contrast target, add a colour-math test
  over all hue buckets, and validate increased-contrast mode. *(VS-054, #47)*
- **Unlock and error focus are not keyboard-first.** The `.allVaults` default
  makes a sole Vaultwarden password field require a sidebar click first, the
  field has no `@FocusState`, and errors are red text with no focus movement,
  announcement, or non-colour symbol. *(VS-053)*
- **Status relies on subtle colour and tiny secondary text.** Every status needs
  icon plus text, adequate contrast, and a discoverable details action.
  *(VS-041)*
- **No reduced-motion, increased-contrast, Dynamic Type or localization review
  has been done.** *(#48 46)*
- **Never put a secret into feedback or accessibility text.** *(VS-040)*

---

## 9. Governance, claims, and testing

- **The README overstates readiness.** It says providers and writes are
  implemented end to end, offline cache is usable, archive works and multiple
  vaults operate, while `RELEASE_ELIGIBILITY.md` says no release evidence set
  exists. Split the status into "code present", "fake-boundary tested",
  "live-contract tested" and "release admitted". Never label a capability
  supported because code exists. *(VS-044, #33 1, #48 1)*
- **Workstream status is stale and contradictory** across `DELIVERY.md`, the
  workstream records and the README. One machine-readable feature and evidence
  manifest should drive the README tables, release gating and UI capability
  admission. *(VS-045)*
- **The flat AEAD cache is not the planned encrypted database.** `EncryptedStore`
  is a protocol and a test double; there are no row-level updates and no WAL,
  migration or crash evidence. Workstream 5 is not done. *(VS-014, #48 14)*
- **Account email is persisted to `UserDefaults`** while the security plan
  treats account identifiers as high sensitivity. Needs an explicit
  reconciliation in a controlling document. *(VS-015)*
- **UI coverage stops near the shell.** No coverage of successful login or 2FA,
  unlock, list and detail, reveal and copy, create/edit conflict, archive,
  per-vault lock, search navigation, large text, or error focus. *(VS-046)*
- **`scripts/check-repository.sh` is environment-fragile** — it needs `python3`
  and says so only by failing. Preflight the tools with an actionable message.
  *(VS-048)*
- **The lock timeout default of 15 minutes differs from the plan's recommended
  5.** Reconcile the number or the plan. *(#48 41)*

### Process

These are observations about how the work was done rather than about the code,
and they are kept because the eight documents this file replaces are themselves
the evidence for the first one.

- **Parallel review passes that cannot see each other produce duplicate
  implementations.** Three password generators, three auto-lock settings, five
  Quick Search branches and seven files called `ANALYSIS.md` were written
  against the same base at the same time. Several reviewers noticed mid-pass and
  started annotating findings with "check `<branch>` before adding a second" —
  which worked, and is the practice to keep: read the open pull request list
  before starting, and say in the document which branch already owns a finding.
  *(#47, #33)*
- **Do not bundle visual redesign, new item types, or product surface into a
  security fix.** A security change should be reviewable on its own terms; the
  broad-but-shallow branch that mixed hardening with disabling writes and
  narrowing providers is the reason that pull request cannot be merged as a
  branch at all. *(#48, #52)*
- **Clean-room attestation is a per-document obligation.** Each of these
  reviews recorded that it inspected no production vault material, no vendor
  credentials, and no prohibited source history. That record travels with the
  finding, not just with the pull request that carried it. *(#48, #33)*

---

## 10. Ideas worth stealing

Concepts, not commitments. Several touch security controls and are marked.

- **Screenshot shyness.** While a secret is revealed, set the window's
  `sharingType` to `.none` so screen recordings and screenshots capture a blank
  pane. One line, and the kind of thing users tell each other about. *(D1, #72,
  #48 4)*
- **The Squire.** The app has a name and a heraldic shield and does nothing with
  either. A mark that latches shut on lock — one 200 ms animation — would give
  it a signature moment. Quiet, not cute. *(#72, #47)*
- **Clipboard countdown in the menu bar.** While a copied secret is live, a tiny
  draining ring; click to clear immediately. It makes the app's best-hidden
  security property its most visible one. *(#72, #52 "clipboard torch",
  #48 10)*
- **A command palette.** ⌘⇧P for app actions — Lock, Sync, Add Item, Generate
  Password, Toggle Site Icons, Settings — which also subsumes several missing
  shortcuts. Quick Search could recognise `>` -prefixed verbs instead, without
  sending queries anywhere. *(N3, #52)*
- **Vault weather.** One line in the sidebar footer: "3 reused · 1 weak · synced
  2 min ago". Local, honest, and a reason to open the app when you do not need a
  password. *(#72, #52 "calm stale-state weather")*
- **Peek with Space.** Select a row, tap Space, get a floating card with the
  username and a copy button without leaving the list. *(#72)*
- **Provider parity table in Settings.** A grid of which actions each connected
  provider supports and why the others are absent. The capability model already
  knows the answer; showing it turns a limitation into transparency. *(#72,
  #52 "why unavailable?", #48 6)*
- **Privacy receipt.** A local, ephemeral panel listing what VaultSquire
  contacted this session by category and count only — "your server: 3 requests;
  provider CLI: 2 runs; site icons: 0" — with no domains and nothing persisted.
  *(#52)*
- **Provider truth badges**: `Offline snapshot • 2h old`, `Read-only via CLI`,
  `Reauthentication needed`, making provider asymmetry feel intentional.
  *(#52)*
- **Memorable and pronounceable generation** with a live entropy readout, and a
  "time to crack" line under generated passwords. *(N5, #66 D4, #48 9)*
- **TOTP import from a QR image** — drop or paste a screenshot and decode the
  `otpauth://` seed. *(N6)*
- **Next-code preview** in the last five seconds of a TOTP window. *(#66 D6)*
- **In-app "recently copied"** — a tiny ephemeral in-memory list of the last few
  copied fields, cleared on lock like everything else. *(N7)*
- **A vault-open window accent** — a barely-there rule or dot while anything is
  unlocked, gone entirely when locked. *(N8)*
- **Recents when empty in Quick Search**, instead of the whole vault
  alphabetically in a 330-point panel. *(N9)*
- **Travel lock** — an intentionally stronger temporary posture that disables
  Touch ID. *(#48 7)*
- **Polite shoulder-surfing mode** — one click hides everything sensitive.
  *(#48 4)*
- **Vault Constellation** — an optional overview of each open vault as a
  tasteful graphic. *(#48 2)*
- **"Archived — tucked away, not deleted"** as the framing once an Archived view
  ships. *(#47)*
- **Copy diagnostic details on CLI failure** — the provider panes already show a
  `resolvedRealPath → approvedPath` arrow; a copyable diagnostic block would
  help users file detection bugs. *(#47)*
- **Haptics on lock and unlock**, and a quiet checkmark the first time Touch ID
  is set up. *(#66 D3, N12)*
- **A teachable-moment toast** after an inactivity auto-lock. *(#66 D7)*
- **Password-age nudge** on the detail pane. *(#66 D5)*
- **Breach checking**, if ever wanted, only as a k-anonymity SHA-1 prefix range
  query. It still sends derived data, so opt-in and off by default — but it is
  the correct way to do it at all. *(N4, #66 M17)* **Needs policy.**
- **Live TOTP in the list row.** The seed is a secret and deliberately not on
  the projection, so this needs decrypt-on-demand per visible row — a real
  secret-surface and performance tradeoff. A safer cousin: a per-row "has TOTP"
  dot with a hover copy that hydrates transiently. *(N1)* **Needs design.**

---

## 11. What is good, and must not regress

Several reviewers wrote this section unprompted. It is kept because a backlog
that only lists faults invites someone to trade away what is working.

- **The security posture is coherent and documented.** Generation-based
  discarding of late results, clipboard ownership gated on the change count,
  fail-closed CLI version gates, no-argv and no-environment secret handling, and
  the "site's own origin, never an aggregator" icon rule are all principled and
  explained in comments.
- **Capability gating is real**, enforced in the use-case layer rather than by
  disabling a button.
- **Per-vault independent sessions** with a merged All Vaults scope is the right
  model and is well implemented.
- **The provider boundary is real rather than aspirational** — the code does not
  pretend the three services share a protocol or a cryptographic model.
- **TOTP is correct** against RFC 6238 and 4226, including Base32 and multiple
  algorithms, digit counts and periods.
- **Deterministic monogram tiles** with a written-out FNV-1a hash are a smart,
  privacy-respecting default that is stable across launches.
- **The comments record why**, including past traps, at a level most codebases
  never reach.
- **The test surface** is broad — roughly 10k lines including leakage, fuzz,
  cancellation and capability tests.
- **Accessibility identifiers are thorough**, which is rare and valuable.
- **The named-residuals culture** in the security reviews (the R5–R8 pattern) is
  worth keeping.
- **Vaultwarden's `unlock()` reads the local sealed cache first**, so the vault
  opens without waiting on the network. This is the resilience the CLI providers
  were missing, and it is the model their offline path was brought in line with.
- **`AutoLockController` was already a complete and correct inactivity lock.**
  Every gap reported against it was in Settings, not in the policy engine.

Two things were examined and found correct, recorded so they are not raised a
third time:

- **`ProtonCLILocator` reading the real user home** is discovery only. It
  resolves where a CLI might be installed; it does not relocate `HOME` for the
  child process, which still runs under the fixed environment allowlist.
- **The `defer { zero(&unwrapped) }` in `VaultwardenKeyUnwrap`** zeroizes a
  buffer nobody else holds, because `Data` is copy-on-write and
  `VaultwardenSymmetricKey` copies into its own storage. It is a no-op rather
  than a live-fire bug — but the reliance on that copy should be commented, so a
  later refactor to a class-backed key type does not silently zero a live key.

---

## 12. Definition of done

Carried forward from #52, kept because every one of the eight source documents
violated it in its own status table.

An item leaves this backlog when its pull request is merged **and** all
applicable positive, negative, cancellation, ambiguity, leakage, accessibility
and performance evidence is linked. "Code exists", "a unit test over a fake
passed", and "an open PR is green" are not synonymous with supported or done.
