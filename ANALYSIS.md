# VaultSquire Product and Engineering Analysis

- Review date: 2026-08-11 (two passes over the same tree: the initial
  `review/password-manager-client` pass, and the `thorough-review-password-manager`
  pass recorded in full in `ds.md`)
- Review environment: Linux repository checkout; no macOS runtime, Xcode, VoiceOver,
  signing, notarization, real CLI, or visual pixel inspection was available
- Scope: static review of the native shell, provider/session code, persistence and
  process boundaries, tests, governance, product claims, and user experience
- Status: forward-looking analysis for future work; subordinate to `PLAN.md`,
  `SECURITY_AND_TESTING.md`, and `ARCHITECTURE.md`

## Executive assessment

VaultSquire has a notably serious security posture for an early password-manager
client: explicit provider boundaries, bounded no-shell CLI execution with an
environment allowlist, fail-closed version gates, session generations, clipboard
ownership checks, AEAD-sealed cache envelopes, unknown-field preservation, origin and
KDF approval flows, and a broad synthetic test suite (~465 unit tests including fuzz
and leakage suites). The clean-room and release-blocking governance is unusually
strong, and the review pass fixed a first round of selection, privacy, and
presentation defects (see the tracker below).

The product surface still runs ahead of its verified readiness in places, several
security requirements are modeled but not enforced (reprompt, key-rotation
reauthentication, user-presence-bound cache keys, CLI identity verification), several
advertised workflows remain absent from the UI (account removal, offline-open path,
unarchive/trash), and the search/list architecture cannot credibly meet the
documented 100k-item interaction budgets without a measured redesign. The visual
shell is coherent but sparse; the browser is nearly all default AppKit chrome while
the empty shell is branded, and the keyboard-first story is incomplete.

No finding below authorizes release. Security and workstream gates continue to
control implementation order.

## Resolution tracker (2026-08-11 pass)

Done means merged, open, or drafted by the review PRs; check the linked PR before
re-raising an item.

| Finding (below) | Status | PR(s) |
|---|---|---|
| 13 per-vault lock keeps site icons | Done | `fix/clear-icons-on-vault-lock` |
| 33–35 settings shortcut/lock copy | Done | `fix/honest-settings-copy`, `feat/autolock-preference` |
| 6 partial CLI snapshot publication | Done | `fix/complete-cli-snapshots` |
| 12 selection reconciliation (+ ds B1 group-scope hand-off) | Done | `fix/browser-selection-correctness` |
| 30 copy confirmation, 24-adjacent text-selection boundary | Done | `feature/copy-confirmation`, `fix/detail-copy-boundaries` |
| ds B3 closed window cannot be reopened | Done | `fix/reopen-main-window` |
| 41 password generation | Done (character-set mode) | `feature/password-generator` |
| ds B5 archive without confirmation/undo | Done (confirmation) | `feature/archive-confirmation` |
| 19-adjacent quick search rendering cap, badge, merged sort | Done | `feature/quick-search-polish` |
| 1 product-claims documentation | In progress | `security-review-password-manager` |

## Priority findings

### P0 — Release and trust blockers

1. **Product claims substantially outrun verified readiness.** The README reads like
   a usable multi-provider application while `RELEASE_ELIGIBILITY.md` says major
   evidence is still outstanding. Rewrite status into "implemented in source,"
   "verified by automated tests," "requires real-Mac evidence," and "not
   implemented/wired" columns. The parallel documentation PR
   (`security-review-password-manager`) is a strong start; finish the sweep.
   Confidence: high.

2. **Master-password reprompt is not enforced.** `requiresReprompt` is preserved by
   the wire model but reveal, copy, edit, and archive do not request fresh
   authentication. Treat as a stop-ship authorization defect with negative tests for
   every action path. Confidence: high (also recorded as R2 in the adversarial
   review). **Open.**

3. **Key-rotation reauthentication is not implemented.** Sync can adopt changed
   wrapped bootstrap keys without atomically retaining the prior snapshot,
   persisting `reauthenticationRequired`, invalidating quick unlock, and blocking new
   secret operations. Implement only as a complete session/storage transaction with
   crash and cancellation tests. Confidence: high (adversarial R1). **Open.**

4. **CLI cache-key release is not bound to user presence.** Proton/1Password
   cache-envelope keys are ordinary device-only Keychain items. The architecture
   requires a user-presence-bound release and session caching of the released key.
   Confidence: high (adversarial R3). **Open.**

5. **CLI executable identity is established only by path and self-reported version.**
   Require code-signature/team/designated-requirement/notarization assessment of the
   resolved executable, persist the approved identity, and detect replacement.
   Confidence: high (adversarial R4 and Workstream 10 gate). **Open.**

6. **Partial CLI refreshes can replace a complete offline snapshot.** Proton and
   1Password refresh loops skipped unreadable vaults and sealed the remainder. Done:
   the refresh now fails closed and the last complete snapshot is preserved.
   Confidence: high. **Done — `fix/complete-cli-snapshots`.**

7. **Real-provider compatibility is unproven.** Both CLI mappings are tested through
   fake executors; the 1Password GUI-without-a-TTY authorization path and the
   Vaultwarden cross-client crypto differential remain outstanding. Preserve
   fail-closed language until disposable live-account and clean-Mac evidence exists.
   Confidence: high. **Open.**

### P1 — Correctness and user-visible bugs

8. **Offline cache reads are implemented below the UI but not wired into the open
   flow.** Add an explicit, authenticated "Open last saved copy" path with
   captured-at and stale/partial status; never silently fall back. Confidence: high.
   **Open.**

9. **Archived and trashed items disappear with no way to view or restore them.** Add
   explicit filters/counts, read-only detail presentation, and unarchive only after
   its dedicated capability and tests pass. Confidence: high. **Open.**

10. **Favorites are editable but not useful.** The edit sheet carries a Favorite
    toggle; browse/search has no Favorites scope, star, or ranking. Either surface
    Favorites coherently or postpone the toggle. Confidence: high. **Open.**

11. **Write conflict and ambiguity feedback is too transient and generic.**
    `writeError` is a single app-level string; there is no durable conflict
    resolution surface or item-scoped retry/reconcile workflow, and no draft
    retention until resolved. Confidence: medium-high. **Open.**

12. **Selection can point at an item no longer in the current filtered result.**
    Done: query changes, sync removals, and scope changes now reconcile the
    selection, and the Quick Search hand-off widens group scopes too. Confidence:
    high. **Done — `fix/browser-selection-correctness`.**

13. **Per-vault lock leaves site icons from that vault in memory and on screen.**
    Done: locking one vault now clears the icon cache. Confidence: high.
    **Done — `fix/clear-icons-on-vault-lock`.**

14. **Quick Search can retain a stale in-memory item snapshot after a vault
    changes.** The floating panel copies projections at presentation and never
    refreshes them; locking one of several vaults leaves its rows advertised. Dismiss
    or live-update on session generation changes. Confidence: high. **Open.**

15. **Account removal/logout is absent from the visible interface.** No remove,
    logout, rename, or reconnect action exists; `AccountDescriptorStore.remove` is
    dead. Add account management with explicit cache/credential deletion semantics
    and confirmation, and replace the misleading "add the account again" copy.
    Confidence: high. **Open.**

16. **Adding the same provider/account has unclear duplicate and replacement
    behavior.** Present existing-account detection and a deliberate
    reconnect/update flow. Confidence: medium-high. **Open.**

17. **Unsupported item types degrade into generic rows rather than useful read-only
    views.** SSH keys are claimed in README text but have no purpose-built surface.
    Preserve safe generic rendering, correct the claim, and add category-specific
    read-only rendering only with leakage-safe tests. Confidence: high. **Open.**

18. **The empty-state recovery copy is misleading.** Replace with account-scoped
    diagnostics and recovery. Confidence: high. **Open.**

19. **ds: the main window cannot be reopened after being closed.** The app
    intentionally outlives its window, but a `Window` scene cannot be recreated and
    no reopen handler existed. Done: `WindowGroup` + `applicationShouldHandleReopen`.
    Confidence: high. **Done — `fix/reopen-main-window`.**

20. **ds: archive is destructive-adjacent with no confirmation and no undo.** Done:
    a confirmation dialog now precedes archiving; unarchive remains a capability
    gate away. Confidence: high. **Done — `feature/archive-confirmation`.**

21. **ds: `VaultSession`/`SessionState` are dead code.** The Workstream 2 session
    actor is exercised only by its own tests; `AppModel` implements the same concerns
    with `VaultSlot` and generations. Two parallel state models disagree by
    construction; wire one in or delete the other. Confidence: high (maintainability).

22. **ds: empty Proton/1Password vaults never appear in the sidebar.** Vaultwarden
    seeds groups from folders; CLI-provider groups are derived only from items, so an
    emptied vault vanishes from the sidebar. Seed from the snapshots' vault lists.
    Confidence: high.

23. **ds: the Add Account success copy mentions the master password for CLI
    providers.** Make the wording provider-dependent. Confidence: high.

### P1 — Performance and responsiveness

24. **Search runs synchronously on the main actor on every keystroke.** Linear
    substring scans cannot meet the 100k-item/250 ms budget. Build a bounded,
    normalized in-memory index off-main, debounce publication, cancel stale queries,
    and measure keystroke-to-render separately. Confidence: high. **Open.**

25. **The aggregate item list is rebuilt and sorted on every access.** Cache sorted
    projections by scope/session generation and update incrementally. Confidence:
    high. **Open.**

26. **Quick Search displays every item for an empty query.** Done: rendered results
    are capped at 100; the merged list is globally sorted; rows carry a source-vault
    badge. Ranked matching still needs the index from 24. Confidence: high.
    **Partially done — `feature/quick-search-polish`.**

27. **Search behavior is below the specified feature contract.** Substring matching
    only; the plan calls for accent/case normalization, prefix matching, quoted
    terms, deterministic ranking, and generated corpora. Share one engine between
    browser and Quick Search. Confidence: high. **Open.**

28. **Item rows can initiate hundreds of icon tasks and requests while scrolling.**
    Add a concurrency limit, cancellation for rows leaving the viewport, MIME/size
    checks, and an account-scoped cache. Confidence: medium-high. **Open.**

29. **Icon byte accumulation is byte-by-byte.** Consume chunks instead of appending
    one byte at a time up to 256 KiB. Confidence: medium. **Open.**

30. **Group derivation repeatedly scans every item and sorts on render.** Cache
    groups when projections publish. Confidence: high. **Open.**

31. **There is no user-visible performance/freshness distinction between loading
    cache, decrypting, indexing, fetching secrets, and syncing.** A single spinner
    makes a multi-minute CLI refresh look hung. Expose staged progress and keep an
    already-open cached list usable during refresh. Confidence: high. **Open.**

32. **PBKDF2 unlock runs off-main (good) but occupies a cooperative thread.**
    Acceptable today; note for the future. Confidence: n/a (note).

### P2 — macOS interface, accessibility, and aesthetics

33. **The app has two visual personalities.** The empty shell is branded; the browser
    is stock chrome. Carry a restrained visual system through the unlocked app.
    Confidence: high from code; requires real visual review. **Open.**

34. **The default window is cramped for a three-column password manager.** Raise the
    default size, define sensible column minimums, test narrow-window collapse.
    Confidence: medium. **Open.**

35. **Detail fields lack grouping and action hierarchy.** Group into sections, keep
    copy/reveal controls aligned, pin common actions. Confidence: high. **Open.**

36. **There is no copy confirmation or clipboard countdown.** Done: copy buttons now
    show a transient "Copied" state, and the parallel boundary PR confines text
    selection to non-secret fields. A visible 30-second countdown remains a
    delightful follow-up. Confidence: high. **Partially done — `feature/copy-confirmation`,
    `fix/detail-copy-boundaries`.**

37. **Toolbar actions are dense and context is weak.** Move secondary/destructive
    actions to context menus or an overflow menu; keep Add and Sync prominent; show
    shortcuts in menus. Confidence: medium-high. **Open.**

38. **Quick Search lacks keyboard result navigation and selection styling.** Return
    always opens the first result; there is no arrow-key navigation, selected row,
    `⌘1/2/3` copy actions, or match highlighting. This is the centerpiece of the
    keyboard-first promise; implement carefully with a tracked selection index and
    macOS 14 `onKeyPress`, and verify on a real Mac before landing. Confidence: high.
    **Open.**

39. **Quick Search is not actually global despite settings wording.** Call it an
    in-app shortcut until a reviewed global shortcut is implemented (the keyboard
    shortcuts spike remains unadopted). Confidence: high. **Open.**

40. **Settings claims configurability the UI does not provide.** Done: the
    inactivity lock now has a real picker and the caption is honest; the global
    shortcut remains fixed and is now described as such. Confidence: high.
    **Done — `feat/autolock-preference`, `fix/honest-settings-copy`.**

41. **The lock timeout default (15 min) differs from the plan's recommended 5 min.**
    Needs an explicit decision; the new picker makes the current default visible.
    Confidence: high. **Open (decision).**

42. **Provider onboarding is text-heavy and cramped at a fixed 420-point width.**
    Use provider cards or a two-step picker, expandable security details, a wider
    adaptive sheet, and clear install/open-terminal help. Confidence: high from code.
    **Open.**

43. **Errors are embedded into sidebar subtitles.** Use a status badge plus an
    accessible detail/retry popover or content-pane recovery view. Confidence: high.
    **Open.**

44. **Disclosure and lock controls create small click targets.** Expand hit regions
    while preserving alignment; verify Full Keyboard Access and VoiceOver.
    Confidence: medium-high. **Open.**

45. **The site-icon privacy toggle is admirable but too verbose.** Lead with one
    crisp sentence and put the threat model under "Learn More." Confidence: medium.
    **Open.**

46. **No reduced-motion, increased-contrast, Dynamic Type, or localization review.**
    Custom gradients, fixed sizes, caption text, and English string interpolation all
    need passes. Confidence: medium. **Open.**

### P2 — Missing product capabilities

47. **Password generation is missing despite being in the first general-use scope.**
    Done: an offline character-set generator (length, sets, ambiguous exclusion,
    guaranteed members) with a dice button, options popover, reveal toggle, and unit
    tests. A passphrase mode (with a reviewed word list) and a strength meter remain
    good follow-ups. Confidence: high. **Done — `feature/password-generator`.**

48. **No duplicate-password, weak-password, reused-password, or breached-password
    health view.** Start with local reuse/weakness checks; any breach API must be
    opt-in or privacy-preserving with its own threat review. Confidence: high as a
    valuable later feature. **Open.**

49. **No account/vault organization beyond folder/share scopes.** Favorites,
    item-type filters, recently used/changed, sorting, tags, pinned searches — all
    can be memory-only and dramatically improve large-vault navigation. Confidence:
    high. **Open.**

50. **No secure notes/card/identity editing surface.** Either label Add as "Add
    Login" or add type-specific drafts after provider mutation gates. Confidence:
    high. **Open.**

51. **No duplicate detection or save-time URI normalization assistance.** Offer
    non-blocking warnings for same title/username/site and suspicious schemes; never
    silently rewrite user data. Confidence: medium-high. **Open.**

52. **No command palette or menu-bar workflow.** A reviewed optional menu-bar extra
    could provide Lock All, Quick Search, copied-secret countdown, and vault status
    without exposing item data. Confidence: medium. **Open.**

53. **No secure import/export, passkeys, attachments, autofill, or browser
    integration.** Correctly deferred; make the absence explicit in user-facing
    status rather than implying parity with full clients. Confidence: high. **Open.**

54. **ds: no copy-from-row and no keyboard copy for the selected item.** A `⌘C` on a
    selected row (through the expiry path) and a row context menu would complete the
    keyboard story. Confidence: high. **Open.**

55. **ds: no folder picker on create/edit; no custom-field editing.** New items are
    always created unfiled and edits cannot move folders even though the write path
    preserves them. Confidence: high. **Open.**

## Delightful and differentiating ideas

These are product ideas, not implementation authorization.

1. **Squire Mode:** a compact, keyboard-driven panel where typing narrows results and
   pressing `⌘1`, `⌘2`, or `⌘3` copies username, password, or TOTP without opening
   the main window. Each action shows only a non-secret confirmation and starts the
   clipboard countdown.
2. **Vault Constellation:** an optional overview showing each open vault as a tasteful
   card with freshness, provider, item count, read/write capability, and lock state —
   no secret-derived content.
3. **Tiny heraldry:** extend the deterministic monograms into subtle provider-neutral
   "crests" generated locally from hostname hashes — more distinctive than colored
   letters, still zero network and zero leakage.
4. **Polite shoulder-surfing mode:** a one-click presentation mode that hides
   usernames, URLs, titles, and icons until hovered or keyboard-focused. Never
   described as screen-capture protection.
5. **Secret choreography:** after copy, animate only the copy icon into a small ring
   representing expiry; never animate or reveal the secret. The visual state becomes
   both delightful and security-informative (the "Copied" state is step one).
6. **Contextual "why disabled?" explanations:** capability-gated actions can expose a
   concise reason ("1Password is read-only through the official CLI") instead of
   feeling broken.
7. **Travel lock:** an intentionally stronger temporary posture that disables Touch ID
   quick unlock and purges provider snapshot keys until the next full authentication,
   with a careful recovery design.
8. **Local security garden:** a calm, entirely local health page where reused/weak
   credentials become small plants needing attention. Optional metaphor; always paired
   with plain-language accessibility labels.
9. **Password pastiche:** a themed "sentence" generation mode (adjective-noun-verb-
   number templates from a small local list) as a middle ground between random
   strings and full diceware — no external word list needed.
10. **Copy whisper:** show the secret's 30-second countdown in the toolbar's status
    capsule after a copy, so expiry is visible without opening the detail pane.

## Recommended implementation sequence

The following are reasonable high-confidence candidates, each one reviewable PR, in
dependency order:

1. Finish the documentation truthfulness sweep started by
   `security-review-password-manager` (finding 1) — README/status evidence columns.
2. Account management: remove/logout/reconnect with explicit cache and credential
   deletion semantics and confirmation (findings 15, 16, 18), plus the
   provider-dependent success copy (ds 23).
3. Offline-open path for CLI providers with captured-at and staleness status
   (finding 8), plus partial-status surfacing if the snapshot contract changes.
4. Wire or delete `VaultSession` (ds 21); seed empty CLI-provider groups (ds 22);
   reconcile the Quick Search stale snapshot on session generation changes
   (finding 14).
5. Design and implement reprompt, key-rotation reauthentication, and user-presence
   cache-key flows (findings 2–4) only as individually reviewed security changes with
   all required negative/cancellation/leakage tests.
6. Replace duplicate search implementations with a measured off-main index (findings
   24, 27, 31) as a dedicated performance PR, then layer keyboard result navigation
   on Quick Search (finding 38).
7. Icon-fetch concurrency and chunked reads (findings 28, 29) as a small
   performance/privacy PR.
8. Favorites, archived/trash filters, and non-login editing (findings 9, 10, 50) once
   the capability gates are agreed.
9. Visual system pass (finding 33): carry the shell's restrained branding through the
   browser, widen the window, group detail fields, and thin the toolbar (findings 34,
   35, 37).

Do not bundle visual redesign, new item types, or advanced product ideas into
security fixes. Real-Mac screenshots, keyboard navigation, VoiceOver, Instruments,
provider CLI, signing, and clean-install evidence remain mandatory before declaring
those areas complete.

## Verification notes

- `./scripts/check-repository.sh` began successfully and confirmed version `0.1.0`
  plus the release block, then stopped because `python3` is unavailable in this Linux
  environment. This is an environment/tooling portability limitation; it is not
  evidence that the repository gate passed or that product tests failed.
- No macOS-only build, XCTest, UI test, signing, entitlement, sandbox, performance,
  visual, accessibility, CLI, or hardware result is claimed here.
- The code changes in the PRs listed above were written against the pinned source
  tree and reviewed by static reading only; every PR must pass the normal CI gates on
  macOS before merge.
- No production vault material, vendor credentials, external provider output,
  Keyguard source, or source-derived Keyguard design was inspected.
