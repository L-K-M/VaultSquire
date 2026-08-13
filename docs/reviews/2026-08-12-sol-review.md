# VaultSquire review — sol

- **Reviewer:** sol (BigBoyDevBox), a fresh pass over the current tree.
- **Review base:** `905d76d` (`main` at the time of writing; 67 commits past the
  `0c05294` base the eight consolidated reviews examined).
- **Environment:** Linux. There is no macOS Swift toolchain here, so **nothing
  in this document was compiled or executed**; every judgement is from reading
  code and tests. The `macOS Product` lane (`./scripts/ci.sh` on the hosted
  `macos-26` runner) is the executing gate for every claim that needs a build.
  No macOS, accessibility, performance, or hardware claim is made from this
  environment.
- **Clean-room attestation:** this review inspected no production vault
  material, no vendor credentials, no CLI output from a real machine, and no
  Keyguard-derived or pre-export history. All examples are synthetic. The
  attestation travels with this document.
- **Companion documents:** the consolidated backlog
  ([`2026-08-12-consolidated-backlog.md`](2026-08-12-consolidated-backlog.md))
  remains the canonical home of the eight parallel reviews. This document
  re-derives status from the current code, carries forward everything still
  open, and adds what a fresh pass found. Entries keep their backlog origins
  (`VS-…`, `B…`, `#72`, …) so a reader can trace them; `S-…` entries are new
  here.

### Mid-pass update: PR #79 merged while this review was being written

`main` advanced from `905d76d` to `f48084e` by merging #79, which closed or
partially closed several entries this review was written against:

- **Global system-wide Quick Search hotkey** with an in-Settings chord
  recorder (`GlobalHotkey`, `QuickSearchShortcut`, `QuickSearchShortcutStore`,
  `ShortcutRecorder`) — closes M2 / B10 / VS-032 / #66 M1, and updates
  `docs/dependencies/keyboard-shortcuts.md`.
- **Quick Search copy actions with honest outcomes** — Return runs the item's
  primary action, ⇧Return copies the username, ⌥Return copies the one-time
  code, ⌘Return shows the item in the main window, a footer says what Return
  will do, and fetch failures/cancellations report back instead of failing
  silently — closes U4 / D2 and the Quick Search half of #47.
- **Window-sizing fixes**: a minimum content-column width, the locked-vault
  pane scrolls with a width floor, Settings prose gets a maximum width and a
  stated default window size (620 × 520) — the Settings-wider-than-the-screen
  failure is fixed; the general "default window is cramped" note (#48 34)
  and the fixed edit-sheet size (VS-036) remain open.

Statuses throughout this document are re-derived against `f48084e`; where an
entry is now done it is marked *(done in #79)* instead of removed, so the
record of what closed it survives.

## How to read this

The consolidated backlog marked many items "Closed by the consolidation" —
most landed between `0c05294` and `905d76d`. I spot-checked each closed item
against the current code; they are indeed fixed (reveal/copy timer retention,
Quick Search secret retention after dismiss, clipboard bypass via text
selection, archive confirmation, password generator, auto-lock settings, row
context menus, TOTP progress ring, icon publish batching, CLI process stream
bounds, descriptor fail-closed decode, transport and icon-fetch hardening,
TOTP input bounds, Steam `steam://` support, `MainActor.assumeIsolated`
monitors — all present and coherent on `main`).

Everything below is what remains, or is new. Sections follow the areas the
review was asked to focus on.

---

## 1. Bugs and general issues

### 1.1 Confirmed present in the current tree

- **S-01 — `AppModel.unlockError` is dead UI state.** Every unlock path sets
  and clears it, and nothing reads it: the locked-vault pane renders the
  failure from `VaultSlot.state.failed(message)`. One of the two failure
  surfaces should go, or the state should be removed. (`AppModel.swift`; the
  only reader candidates are the views, and none consume it.)
- **VS-068 / S-02 — one unlock reopens a vault the user deliberately locked.**
  `AppModel.finishOpen` calls `openCredentialFreeVaults()`, which opens every
  CLI vault that is neither open nor opening — including a Proton or 1Password
  vault the user locked on purpose this session. The README's "one unlock opens
  the app" is about vaults the unlock gesture is authorized to open; it should
  not override an explicit per-vault lock. Track vaults the user locked by
  hand and skip them until the user opens them again. *(VS-068, unique to #72)*
- **B8 / S-03 — an open Quick Search panel does not see a sync.** Locking
  refreshes the panel; a successful sync still does not.
  `ApplicationCoordinator.refreshQuickSearch()` needs a caller on every
  sync-success path (`AppModel.syncNow`, all three providers). *(B8, VS-051)*
- **S-04 — two search implementations.** The browser still filters with a
  substring `matches` that allocates a haystack array per item per keystroke;
  Quick Search has a ranked, precomputed-haystack matcher. They should be one
  matcher — the ranked one, so the browser list orders by relevance while
  searching. No debounce or cancellation on either. *(#72, VS-019/028/033,
  M11, P3/P4 #69)*
- **S-05 — `AppModel.allOpenItems` re-sorts the whole open corpus on every
  access.** It is a computed property with a `localizedCaseInsensitiveCompare`
  sort, and the sidebar's `openSummary` reads it on every body pass — every
  keystroke in the search field, every model publish, every sync-state toggle.
  On a large vault this is a full sort of the vault per redraw. `items` was
  cached for exactly this reason; `allOpenItems` needs the same treatment.
  *(new; same family as P1/P2/P5, VS-020)*
- **S-06 — `AppModel.mutate` rebuilds derived lists on every mutation.** The
  funnel calls `refreshGroups()` (one pass over items plus a sort) and
  `rebuildItems()` (a scoped sort) even when the mutation only toggled
  `isSyncing` or cleared a `syncError`. Guard the rebuilds on the values they
  depend on (items, folder names, open state). *(new; refined from P1/P2/P5)*
- **S-07 — `detail(for:)` and `draft(for:)` decrypt per body pass.** The
  detail pane calls `detail(for:)` from its body; the toolbar calls
  `canEdit(_:)` (which builds a full draft) on every redraw; each call runs
  AES-CBC decrypt + HMAC verify per field and a linear cipher scan. Memoise
  per item id + snapshot generation for the Vaultwarden path (the CLI paths
  are plaintext lookups and cheap). *(P4 #72, #66 P4)*
- **B9 / B8 / VS-024 — `SiteIconStore` session-state defects.** (a) A host is
  marked attempted before the await, so one transient network failure
  disables its icon for the rest of the session (only cancellation is
  forgiven today). (b) Once `images + pending` reaches the 500-icon cap, no
  new host ever loads — no eviction. (c) No in-flight concurrency limit: fast
  scrolling bursts dozens of concurrent fetches. *(B9, #66 B8, VS-024, #47)*
- **VS-025 / B5 — TOTP row re-derives the code every second.** The
  `TimelineView` re-runs `VaultwardenTOTP.generate` (a full HMAC) once a
  second although the code changes once per period; only the countdown needs
  to tick. The ceiling round also shows a stale-looking "1s" at the boundary.
  *(VS-025, #72, #69 P5, B5)*
- **Known / #72 — ambient pointer motion defeats the idle lock.**
  `AutoLockController` counts `.mouseMoved` as activity, so hovering the
  pointer over the window keeps the vault unlocked indefinitely. Keystrokes,
  clicks, and scrolls are the honest signals. This is a security decision as
  much as a performance one. *(#72, VS-023)*
- **VS-050 — local persistence failures are reported as network success.**
  `VaultwardenAccountService.syncGated` and `performWrite` persist the rotated
  refresh token and the sealed snapshot with `try?`, then return success; the
  UI shows data that was never durably sealed. Needs a distinct
  "showing unsaved state" signal. *(VS-050)*
- **#47 — Vaultwarden collections are never decoded.** `VaultwardenSyncResponse`
  decodes profile, folders and ciphers only, so an organization item filed
  only under a collection has empty `groupingLabels` and is invisible to
  sidebar grouping and collection search, though `PLAN.md` lists collections
  in scope. *(#47, unique)*
- **ds-B11 — empty CLI-provider vaults never appear in the sidebar.**
  Vaultwarden folders are seeded from `folderNames`, but Proton/1Password
  groups derive from items alone; an empty Proton vault or 1Password vault is
  invisible. The snapshots carry the vault list — seed groups from it.
  *(ds-B11)*
- **#47 — the vault count is silently capped at 50** for both CLI providers,
  with no error, count, or "and N more". *(#47)*
- **VS-018 — a transport failure claims "the change was not saved"**, but a
  connection can fail after the server committed. Distinguish pre-send from
  ambiguous failure, keep the draft, block blind retry. *(VS-018, #48 11)*
- **VS-059 — `VaultSession`/`SessionState` is a tested state machine
  production code does not use.** Wire it in as the single authority or delete
  it and move its invariants into the live model. *(VS-059, ds-21)*
- **G2 / M8 — a second Vaultwarden account silently replaces the first.**
  Credentials are keyed to `AccountID.vaultwardenPrimary` and the form offers
  itself again with no warning. *(G2, M8, #48 16, #72)*
- **#72 — a second submit is dropped in silence.** `save(_:to:)` opens with
  `guard !isWriting else { return }`. Narrow (the button disables) but the
  guard should not be the only answer. *(#72)*
- **VS-026 / G5 / M7 — archived items cannot be browsed or restored.**
  `restoreItem` is unused; no Archived or Trash filter, though `PLAN.md`
  requires one. *(VS-026, G5, M7, M11, #47, #48 9)*
- **S-08 — `otpauth://…?encoder=steam` is not recognised.** Only Bitwarden's
  `steam://` form routes to the Steam derivation; a seed exported from Aegis
  or KeePassXC produces a plausible six-digit code that will never work — a
  confidently wrong answer rather than a fail-closed one. *(found while
  integrating #67)*
- **VS-071 — 1Password OTP fields** are read from the field's `value` and fed
  to `VaultwardenTOTP.generate`; if some `op` build returns a generated code
  there rather than an `otpauth://` URI, the row reads "Unreadable one-time
  code seed". A bare-6–8-digit fallback costs nothing. *(VS-071, unique to
  #72)*
- **B10 — `NSApp.activate()` may not raise the app** for Quick Search on
  recent macOS; consider `activate(ignoringOtherApps:)` after interactive
  testing. *(#66 B10)*
- **#72 — `lock(_:)` clears the clipboard for an unrelated vault.** Copy from
  vault A, lock vault B, lose A's copy. Defensible, undocumented, surprising.
  *(#72)*
- **S-09 — CLI rows never offer "Copy One-Time Code"** even after their
  secrets are fetched, because the row menu reads `hasOneTimeCode` from the
  projection, which is false for both CLI providers by construction. The
  detail view offers the copy; the row could too once `detail(for:)` is cheap
  (it is, for CLI items). *(new)*

### 1.2 Security items that remain open (carried forward)

These are release gates in `RELEASE_ELIGIBILITY.md` / `SECURITY_AND_TESTING.md`;
this review changes none of their status.

- Master-password reprompt is not enforced: `requiresReprompt` is preserved on
  the wire but reveal, copy, edit and archive never ask for fresh
  authentication. *(VS-011, R2, #48 2, #72)*
- Key-rotation reauthentication is incomplete: detect rotation, persist
  `reauthenticationRequired`, retain the prior snapshot, invalidate quick
  unlock, refuse secret operations, clear only on complete reauth — one
  transaction with crash and cancellation tests. *(VS-004, R1, #48 3)*
- CLI cache-envelope keys are not bound to user presence (device-only Keychain
  item; snapshots disclose inventory though not secret values).
  *(VS-010, R3, #48 4)*
- CLI executable identity rests on path + self-reported version; require code
  signature, team identity, designated requirement, and notarization
  assessment of the resolved executable, persisted and re-checked.
  *(VS-009, R4, #48 5)*
- Accessibility identifiers embed vault content: `reveal-\(field.label)` and
  `open-uri-\(field.label)`, where the label can be a user's custom-field
  name, put vault-derived strings into the accessibility tree and any UI test
  keyed on them. *(VS-067, unique to #72)*
- `sessionExpired` is displayed as an error, not a state transition: a revoked
  refresh token leaves the decrypted vault open and permits repeated doomed
  operations. *(VS-049)*
- Initial sign-in reports success without a complete first snapshot:
  `persistAfterLogin` seeds an empty snapshot best-effort. *(VS-003)*
- No secure logout or account-removal transaction; `AccountDescriptorStore.remove`
  is dead code and nothing deletes tokens, caches, biometric envelopes, or CLI
  cache keys. *(VS-012, G1, #48 15)*
- Untested CLI releases sit in the production allowlists (Proton 2.2.3–2.2.6,
  1Password five stable releases) with in-code comments saying none was
  exercised against a live CLI. Empty is the safe pre-evidence state.
  *(VS-001)*
- Vaultwarden create/update/archive are exposed before their conflict,
  ambiguity, leakage and official-client evidence exists. *(VS-002)*
- Real-provider compatibility is unproven: both CLI mappings are tested only
  through fake executors, the 1Password GUI-without-a-TTY authorization path
  is unresolved, and the Vaultwarden cross-client crypto differential is
  outstanding. *(#33 7, #48 7)*
- Email is persisted to `UserDefaults` in the descriptor while the security
  plan treats account identifiers as high sensitivity; needs explicit
  reconciliation in a controlling document. *(VS-015)*
- The inactivity default of 15 minutes differs from the plan's recommended 5;
  reconcile the number or the plan. *(#48 41)*

---

## 2. Performance

Measure on hardware before acting; none of this has been profiled on a Mac.

- **S-05** `allOpenItems` full sort per access (above) — the single most
  likely per-keystroke stall in the current tree besides S-07.
- **S-06** `mutate` rebuilds `groups` + `items` even when nothing they depend
  on changed.
- **S-07** per-body-pass decrypts through `detail(for:)`/`draft(for:)`
  (toolbar `canEdit` decrypts the selected item on every redraw).
- **VS-021 — post-sync projection rebuild decrypts every cipher synchronously
  inside the main-actor `mutate`.** Compute projections off-actor and swap in.
  The merged `contentUnchanged` skip avoids the common case, not the real one.
  *(VS-021, #66 P3, #48 21)*
- **S-04** browser search: substring `contains` per item per keystroke with
  per-item haystack allocation; no debounce or cancellation.
- **S-05-adjacent** `QuickSearchPanelModel.present` maps the whole open corpus
  into `Row`s on the main actor when the panel opens; for a very large vault
  this is a launch stall for the panel. Build rows off-actor.
- **VS-022** no revision-gated or no-change sync path: every sync re-downloads,
  and the whole sealed snapshot file is re-encrypted and rewritten even when
  nothing changed (the merged skip only avoids the in-memory decrypt).
  CLI providers run one child process per vault per refresh. *(VS-022, #48 22)*
- **VS-066** both CLI providers re-probe the CLI version (`--version`) before
  every on-demand secret fetch. *(VS-066, #47)*
- **VS-024 / B9 / B8** favicon fetching: no in-flight concurrency limit, no
  retry after transient failure, no eviction at the cap (all in §1.1).
- **VS-025** TOTP HMAC recomputed every second (in §1.1).
- **#48 32** PBKDF2 unlock runs off-main (correct) but occupies a cooperative
  thread.
- **VS-047** performance fixtures measure presentation, not the corpus path;
  add release-mode generated corpora and signposts around normalization,
  ranking, publication and row render. *(VS-047, #48 31)*
- Whole-file caches amplify memory and write cost; a large sealed file means
  peak memory several multiples of it. *(VS-024)*

---

## 3. Missing features and product gaps

Ordered roughly by value. (Carried forward from backlog §5, re-verified
against current code.)

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
- Fuzzy or subsequence matching with ranking and typo tolerance. *(M11, VS-028)*
- Multi-select and bulk actions. *(#72)*
- Item metadata — created/modified dates and password history, both of which
  the cipher model already carries and nothing displays. *(#66 M10, #72)*

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
  expired, reauthentication required, partial CLI state, never-synced.
  *(VS-031, #72)*
- Unsupported item types should get honest read-only placeholders naming the
  provider and version, not a generic "Item". *(VS-034, #48 17)*

**Platform**

- **A global, system-wide Quick Search hotkey.** *(done in #79 — a
  configurable system-wide chord with a recorder in Settings; gated by
  `docs/dependencies/keyboard-shortcuts.md`.)* *(M2, B10, VS-032, #66 M1)*
- A menu-bar extra: search, copy a one-time code, lock, without raising the
  window. *(M5, N11, #66 M15, #48 52, #72)*
- **S-10 — "Open at login" is absent.** `SMAppService.mainApp` is an Apple
  framework, not a third-party dependency, so this needs no adoption gate —
  and it is one of the first settings a password-manager user looks for.
  *(new)*
- A local vault-health view: reused, weak, short and old passwords, logins
  with no one-time code. Entirely local, works across all three providers.
  *(G13, M18, VS-048, #72)*
- Argon2id unlock — fails closed correctly today; gated by
  `docs/dependencies/argon2.md`. *(VS-013, #66 M14)*
- Passkeys, attachments, SSH-key items, AutoFill, Safari extension, import and
  export, Sends. Deferred by `ARCHITECTURE.md`'s non-goals; listed so the
  absence is a decision. *(M9, M10, VS-035, #66 M19–21)*
- Apple Watch unlock — `LAPolicy.deviceOwnerAuthentication` already covers it;
  low effort. *(M16)*
- Export of non-secret metadata for auditing, or an explicit "no export by
  design" line in Settings. *(#72)*
- Delete and trash for Vaultwarden, which offers archive only. *(#72)*
- **S-11 — a clipboard-expiry preference.** `ClipboardService` documents that
  a shorter expiry "may be layered on later"; Settings has no entry for it.
  A 30s/1m/2m picker is honest surface for one of the app's headline
  protections. *(new)*

---

## 4. Interaction and keyboard

- **U2 — double-click a row to open its first website**; today it only
  selects. *(U2)*
- **U3 — list keyboard actions.** Return opens detail, ⌘Return opens the
  website, ⌘C copies the username, from the list. Return and Space currently
  do nothing there. *(U3, #72)*
- **#72 — ⌘F** (focus search — needs `searchFocused`, macOS 15+), a shortcut
  for the one-time code, and a shortcut to open a website. *(The Quick Search
  panel's own copy chords landed in #79; this entry is about the browser's
  list.)* *(#72)*
- **#72 — type-to-find in the item list**: focus the list, start typing,
  filter immediately, the way Finder behaves. *(#72)*
- **U4 / D2 — "Open and copy password" as one Quick Search action.**
  *(done in #79 — Return runs the item's primary action, ⇧Return/⌥Return copy
  username/one-time code, ⌘Return shows the item, with outcome reporting in
  the footer.)* *(U4, D2, #47)*
- **U5 — a reveal-all toggle** for items with many concealed fields (cards,
  identities). *(U5)*
- **U6 — copy by clicking the value text**, not only the icon button. *(U6)*
- **U8 — a visible "Synced" confirmation** after a manual sync, beyond the
  spinner. *(U8)*
- **#52/#72 — hold-to-reveal**: press and hold while a secret field is
  focused, release to conceal; keep click-reveal as the accessibility
  alternative. *(#52, #72)*
- **#72 — restore the last-selected scope on launch.** Window restoration is
  deliberately off for secret-bearing state, but the scope is not secret.
  *(#72)*
- **G14 / N10 — drag and drop a username or password into another app** — one
  of the few ways to fill a field without an extension; it would go through
  `ClipboardService` so the expiry survives. *(G14, N10, #72)*
- **#47 — a "code sent" confirmation and cooldown** on the emailed 2FA
  challenge; `Send Code` disables only while in flight. *(#47)*
- **#72 — 1Password's "Open" is not the default action** while Proton's is, so
  Return does nothing in that pane. *(#72)*
- **#47 — declining an origin or KDF approval bounces to the generic
  sign-in-failed screen** rather than "you declined X". *(#47)*
- **#66 U3 — wrong-password feedback**: subtle shake, haptic, field refocus.
  *(#66 U3)*
- **#66 U8/U9 — retry affordance on failed vault rows**, and tooltips on
  sidebar failure rows (messages truncate to one line today). *(#66 U8, U9)*
- **VS-042 — empty and error states should offer the next action** — Unlock
  Vault, Open All Available, Clear Search, Retry Sync, Show Supported CLI
  Setup. *(VS-042, #48 42)*
- **S-12 — ⌘⌥C (copy username) silently does nothing** when the detail's
  username field isn't literally labelled "Username" (custom-label imports).
  Fall back to the first plain field, or disable the shortcut honestly.
  *(new)*

---

## 5. Visual issues and layout

- **VS-037 / V1 — two visual personalities.** The empty shell's identity rail
  (gradient, tracked small caps, shield) is the only art direction and appears
  only before the first account exists. Its vocabulary should carry into the
  locked pane, the empty detail, and the Quick Search header. *(VS-037, G12,
  V1, #48 33, #47, #72)*
- **V3 / A1 — detail is a flat field-and-divider list.** Group fields into
  rounded, material-backed cards like macOS Settings — the single biggest
  visual upgrade for the risk. *(V3, A1, VS-040, #48 35)*
- **V2 — detail labels are uppercase and heavy.** Sentence case at subheadline
  weight reads modern; reserve caps for metadata. *(V2)*
- **V4 — detail header is unbalanced** — a 46 pt icon against `.largeTitle`.
  Enlarge the icon or step the title down; a rounded tile background. *(V4)*
- **V6 — the secret mask is a fixed ten bullets** regardless of length. A
  length-aware mask is more honest. *(V6)*
- **#72 — monospaced, grouped secrets**: group passwords in four-character
  runs with subtle colouring for digits and symbols. *(#72)*
- **V7 / A7 — the toolbar status item fights the toolbar** — a bare relative
  timestamp in `fixedSize` with manual padding whose comment explains it is
  compensating for the toolbar capsule. A purpose-built status pill with a
  leading symbol and the word "Synced" would stop needing the hack. *(V7, A7,
  #72)*
- **#72 — the item row truncates the username** because the vault badge shares
  its line and wins the space contest on a narrow window. No density option.
  *(#72)*
- **#72 — the sidebar summary reads as a fragment**: "142 items in 2 open" →
  "142 items · 2 vaults open". *(#72)*
- **#72 — the locked-vault pane is a left-aligned wall** in a wide empty pane.
  Centred in a card with the provider's mark it would read as designed. *(#72)*
- **#72 — the detail placeholder puts an item count in its description**,
  which is where a count should never live. *(#72)*
- **VS-036 / V10 — fixed sizes clip at larger text**: Add Account at 420 pt
  wide with no outer scroll and a 1Password account list that can grow past
  the screen; the edit sheet pinned at 460 × 560 with 54 pt and 70 pt text
  editors. *(VS-036, V10, #47, #72)*
- **#47 — fixed 120 pt label columns** in the KDF-change and origin-approval
  panels risk clipping under Dynamic Type. *(#47)*
- **#48 34 — the default window is cramped** for a three-column password
  manager. *(Note: the open #79 targets window sizing; coordinate before
  acting.)* *(#48 34)*
- **VS-039 — the toolbar is crowded and weakly contextual** — Add, Edit,
  Archive, Sync and Lock All as equal-weight items, mostly disabled. Keep Add
  and Sync primary, move item actions to the detail and context menus, keep
  Lock distinct. *(VS-039, #48 37)*
- **#48 43 — errors are embedded in sidebar subtitles**; a status badge plus a
  details affordance. *(#48 43)*
- **V8 — disclosure and lock controls have small click targets.** *(V8, #48 44)*
- **#48 45 — the site-icon privacy toggle is admirable but verbose**; lead
  with one line. *(#48 45)*
- **#47 — primary actions never use `.borderedProminent`**, relying on
  `.keyboardShortcut(.defaultAction)` alone for hierarchy. *(#47)*
- **#47 — no transitions between Add Account's phases** (form → 2FA →
  approval → success). *(#47)*
- **A4 — spacing varies** across 28/24/22/20/14/12/8; adopt a documented
  4/8/12/16/24/32 scale. *(A4)*
- **#72 — typography mixes** `.largeTitle`, `.title2`, `.system(size: 34)` and
  `.system(.title3, design: .rounded)` across four screens. Pick one scale.
  *(#72)*
- **V13 / A5 — the palette is minimal.** Per-category icon tints, a
  brand-tinted locked shell and restrained gradients would lift perceived
  value without losing the serious tone. *(V13, A5, #66 A3)*
- **N2 / V11 — one accent per provider** for the sidebar icon, locked pane and
  merged-list badge — one dictionary, and merged lists become scannable.
  *(N2, V11, #66 A4, #47, #72)*
- **#72 / #66 A5 — materials, not flat panes**: sidebar `.sidebar` style with
  a material background and a subtly elevated detail surface, the way the
  Quick Search panel already does. *(#72, #66 A5)*
- **A3 — motion.** One animation exists (the sidebar twisty). Vault opening,
  fields appearing, and the lock closing deserve a short snappy transition —
  the lock is the emotional beat of a password manager. A proper locked
  treatment would blur the content behind a material rather than swap layouts.
  *(A3, #66 A1, #72)*
- **A8 — selection and hover refinement** in lists: an accent-tinted leading
  edge or soft fill, and a quiet hover affordance. *(A8)*
- **VS-038 — the app icon is too detailed for small sizes.** The small-size
  review gate is already recorded as open; commission reviewed optical
  variants under the provenance process. *(VS-038)*
- **#47 — a witty empty state for a freshly created, item-less vault** — the
  code comments already have an established editorial voice. *(#47)*

---

## 6. Accessibility

- **#47 — copy and reveal buttons have `.help()` tooltips but no
  distinguishing `.accessibilityLabel`**, so VoiceOver likely announces every
  copy button identically. *(#47)*
- **VS-054 — monogram colours are not contrast-safe.** A fixed HSB brightness
  over an 18% tint of the same hue means yellow and green regions of the hue
  range can be permanently hard to read, with no colourblind differentiator.
  Derive separate light and dark tones against a minimum contrast target, add
  a colour-math test over all hue buckets, and validate increased-contrast
  mode. *(VS-054, #47)*
- **VS-053 — unlock and error focus are not keyboard-first.** The `.allVaults`
  default makes a sole Vaultwarden password field require a sidebar click
  first; the field has no `@FocusState`; errors are red text with no focus
  movement, announcement, or non-colour symbol. *(VS-053)*
- **VS-041 — status relies on subtle colour and tiny secondary text.** Every
  status needs icon plus text, adequate contrast, and a discoverable details
  action. *(VS-041)*
- **#48 46 — no reduced-motion, increased-contrast, Dynamic Type or
  localization review has been done.** *(#48 46)*
- **VS-067 — accessibility identifiers embed vault content** (see §1.2).
- **VS-040 — never put a secret into feedback or accessibility text.**
  *(VS-040)*

---

## 7. Governance, claims, and testing

- **VS-044 — the README overstates readiness.** It says providers and writes
  are implemented end to end, offline cache is usable, archive works, while
  `RELEASE_ELIGIBILITY.md` says no release evidence set exists. Split status
  into "code present", "fake-boundary tested", "live-contract tested",
  "release admitted". *(VS-044, #33 1, #48 1)*
- **VS-045 — workstream status is stale and contradictory** across
  `DELIVERY.md`, the workstream records and the README. One machine-readable
  feature and evidence manifest should drive the README tables, release
  gating and UI capability admission. *(VS-045)*
- **VS-014 — the flat AEAD cache is not the planned encrypted database.**
  `EncryptedStore` is a protocol and a test double; no row-level updates, WAL,
  migration or crash evidence. Workstream 5 is not done. *(VS-014, #48 14)*
- **VS-046 — UI coverage stops near the shell.** No coverage of successful
  login or 2FA, unlock, list and detail, reveal and copy, create/edit
  conflict, archive, per-vault lock, search navigation, large text, or error
  focus. *(VS-046)*
- **VS-048 — `scripts/check-repository.sh` is environment-fragile** — it needs
  `python3` and says so only by failing. Preflight the tools with an
  actionable message. *(VS-048)*
- **#48 41 — lock timeout default (15 min) differs from the plan's
  recommended 5.** Reconcile the number or the plan. *(#48 41)*
- Process notes from the consolidation carry forward unchanged: read the open
  PR list before starting; do not bundle redesigns into security fixes; record
  the clean-room attestation per document.

---

## 8. Ideas worth stealing (novel, cool, delightful)

Concepts, not commitments. Several touch security controls and are marked.

- **D1 — screenshot shyness.** While a secret is revealed, set the window's
  `sharingType` to `.none` so screen recordings capture a blank pane. One
  line, and the kind of thing users tell each other about. *(D1, #72, #48 4)*
- **The Squire.** The app has a name and a heraldic shield and does nothing
  with either. A mark that latches shut on lock — one 200 ms animation — would
  give it a signature moment. Quiet, not cute. *(#72, #47)*
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
- **Memorable and pronounceable generation** with a live entropy readout and a
  "time to crack" line under generated passwords. *(N5, #66 D4, #48 9)*
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
- **S-13 — category chips above the list** (All / Logins / Cards / Notes /
  Identities) — cheap, scannable, and works with the merged All-Vaults scope.
  *(new)*
- **S-14 — an unlock ceremony.** The first unlock after installation could end
  on a one-line summary ("142 items · synced 2 min ago · Touch ID ready") —
  a micro-onboarding that teaches the app's language. *(new)*
- **S-15 — show the clipboard countdown in the detail's copy receipt and the
  row context menu** so the expiry is visible exactly where the copy happened
  (the detail already does this; the row does not). *(new)*

---

## 9. What is good, and must not regress

Carried forward from the consolidated backlog and re-verified against
`905d76d`:

- The security posture is coherent and documented: generation-based discarding
  of late results, clipboard ownership gated on the change count, fail-closed
  CLI version gates, no-argv/no-environment secret handling, and the "site's
  own origin, never an aggregator" icon rule.
- Capability gating is real, enforced in the use-case layer rather than by
  disabling a button.
- Per-vault independent sessions with a merged All Vaults scope is the right
  model and is well implemented.
- The provider boundary is real rather than aspirational.
- TOTP is correct against RFC 6238/4226, including Base32, multiple
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

---

## 10. Implementation plan for this pass

Small, high-confidence, individually reviewable changes, each on its own
branch from `main`, touching disjoint files so the pull requests do not fight
each other. None of this is compiled here; the `macOS Product` CI lane is the
first build of each. The plan deliberately avoids everything the open PR #79
already owns (window sizing, Settings layout, the global hotkey) and avoids
the still-open release-gate security work, which needs design first.

| Branch | Entry | What it changes | Files |
|---|---|---|---|
| `sol/autolock-activity-semantics` | #72 / VS-023 | Drop `.mouseMoved` from the activity mask so ambient hover no longer defeats the idle lock; expose the mask for a test. | `AutoLockController.swift`, `AutoLockControllerTests.swift` |
| `sol/appmodel-session-fixes` | VS-068, B8 | Honor deliberate per-vault locks when the unlock gesture opens credential-free vaults; refresh a visible Quick Search panel after every successful sync. | `AppModel.swift`, `AppModelTests.swift` |
| `sol/appmodel-redundant-work` | S-05, S-06, S-07 | Cache `allOpenItems` like `items`; skip `refreshGroups`/`rebuildItems` when nothing they depend on changed; memoize the Vaultwarden `detail`/`draft` for the selected item per snapshot generation, dropped on lock. | `AppModel.swift`, `AppModelTests.swift` |
| `sol/browser-interaction-polish` | U2, #72 | Double-click a row opens its first website (through the existing URI confirmation); sidebar summary reads "142 items · 2 vaults open"; the detail placeholder drops the item count from its description. | `VaultBrowserView.swift` |
| `sol/detail-view-polish` | V6, #47, VS-067, VS-025/B5 | Length-aware secret mask; index-based accessibility identifiers (no vault-derived labels in identifiers); accessibility labels on reveal buttons; generate the TOTP code once per period and let only the countdown tick. | `VaultItemDetailView.swift` |
| `sol/site-icon-store-resilience` | B9, B8, VS-024 | Forgive transient fetch failures (bounded retries per host), evict the oldest icon at the cap instead of freezing, cap in-flight fetches so scrolling cannot burst unbounded requests. | `SiteIconStore.swift`, `ItemIconTests.swift` |
| `sol/check-repository-preflight` | VS-048 | Preflight `python3` (and the other tools the script shells out to) with an actionable message instead of an unexplained failure. | `scripts/check-repository.sh` |

Conflict-avoidance notes: the two AppModel branches touch disjoint regions of
one file and merge in either order; everything else touches a file no other
branch in this set touches. All branches are written against current `main`,
not against each other.

Everything else in this document stays backlog — in particular the release
gates (§1.2), the unified-search workstream (S-04), the visual system work
(§5), and the larger product gaps (§3), which deserve their own design and
their own PRs rather than being smuggled into a review pass.

## 11. Definition of done

An item leaves the backlog when its pull request is merged **and** all
applicable positive, negative, cancellation, ambiguity, leakage,
accessibility, and performance evidence is linked. "Code exists", "a unit test
over a fake passed", and "an open PR is green" are not synonymous with
supported or done. This pass's branches state their own unverified
assumptions; the macOS lane is the executing gate.
