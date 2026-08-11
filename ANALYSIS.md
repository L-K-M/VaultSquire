# VaultSquire Product and Engineering Analysis

## Implementation status

- PR #31 corrects the misleading global-shortcut and configurable-lock wording (findings 33–35); remove those findings after the PR merges and macOS CI passes.
- PR #32 clears the shared site-icon cache on per-vault lock (finding 13); remove that finding after the PR merges and macOS CI passes.
- All other findings remain open. No item is treated as complete merely because a PR exists.

- Review date: 2026-08-11
- Review environment: Linux repository checkout; no macOS runtime, Xcode, VoiceOver, signing, notarization, real CLI, or visual pixel inspection was available
- Scope: static review of the native shell, provider/session code, persistence and process boundaries, tests, governance, product claims, and user experience
- Status: review findings; this document is subordinate to `PLAN.md`, `SECURITY_AND_TESTING.md`, and `ARCHITECTURE.md`

## Executive assessment

VaultSquire has a notably serious security posture for an early password-manager client. It has explicit provider boundaries, bounded CLI output, fail-closed version gates, session generations, clipboard ownership checks, encrypted cache envelopes, unknown-field preservation, and a broad synthetic test suite. The clean-room and release-blocking governance is unusually strong.

The product description, however, has advanced faster than its verified product surface. The README reads like a usable multi-provider application while the controlling records still describe major release evidence as outstanding. Several security requirements are modeled but not enforced, several advertised workflows are absent from the UI, and the current search/list architecture cannot credibly meet the documented 10,000- and 100,000-item interaction budgets without measurement and redesign. The visual shell is coherent but sparse and utility-like; it lacks the hierarchy, feedback, customization, and small moments of polish expected of a high-value macOS app.

No finding below authorizes release. Security and workstream gates continue to control implementation order.

## Priority findings

### P0 — Release and trust blockers

1. **Product claims substantially outrun verified readiness.** `README.md` says Vaultwarden is implemented end to end, offline caches are usable, multiple vaults open together, and both CLI providers work read-only. `RELEASE_ELIGIBILITY.md` simultaneously says Workstreams 2–7 and Workstream 8 hardening are incomplete and no release evidence set exists. This is not merely stale documentation: it can cause reviewers and future contributors to treat unverified behavior as complete. Rewrite the status into “implemented in source,” “verified by automated tests,” “requires real-Mac evidence,” and “not implemented/wired” columns. Confidence: high.

2. **Master-password reprompt is not enforced.** The wire model preserves `requiresReprompt`, but reveal, copy, edit, and archive paths do not request fresh authentication. Quick unlock and an already-open session therefore satisfy operations that the architecture says require re-verification. Treat this as a stop-ship authorization defect and add negative tests for every action path. Confidence: high; also recorded as R2 in the adversarial review.

3. **Key-rotation reauthentication is not implemented.** Sync can adopt changed wrapped bootstrap keys without atomically retaining the prior snapshot, persisting `reauthenticationRequired`, invalidating quick unlock, and blocking new secret operations. The next password unlock can misleadingly report a bad password. Implement this only as a complete session/storage transaction with crash and cancellation tests. Confidence: high; adversarial review R1.

4. **CLI cache-key release is not bound to user presence.** Proton and 1Password cache-envelope keys use ordinary device-only Keychain items. The architecture requires a user-presence-bound release and session caching of the released key. Although current CLI snapshots intentionally omit secret values, they disclose account inventory, titles, usernames, URLs, and vault names. Confidence: high; adversarial review R3.

5. **CLI executable identity is established only by path and self-reported version.** A replaced `pass-cli` or `op` binary at an allowlisted path can report an admitted version. Require code-signature, team-identity, designated-requirement, and notarization assessment of the resolved executable, persist the approved identity, and detect replacement. Confidence: high; adversarial review R4 and Workstream 10 gate.

6. **Partial CLI refreshes can replace a complete offline snapshot.** Proton and 1Password refresh loops skip unreadable vaults and seal the remainder. This silently turns a transient per-vault failure into missing offline inventory. Fail the refresh and preserve the last complete snapshot, or explicitly model partialness and prevent a partial snapshot from becoming the last-known-good complete state. The first option is safer and simpler. Confidence: high; adversarial review R7.

7. **Real-provider compatibility is unproven.** Both CLI mappings are tested through fake executors, the 1Password GUI-without-a-TTY authorization path is unresolved, and the Vaultwarden cross-client crypto differential remains outstanding. Preserve fail-closed language and do not describe the integrations as operationally supported until disposable live-account and clean-Mac evidence exists. Confidence: high.

### P1 — Correctness and user-visible bugs

8. **Offline cache reads are implemented below the UI but not wired into the open flow.** Proton and 1Password services expose cached snapshots, yet `AppModel.openProton` and `openOnePassword` perform a live refresh and fail the row if it fails. README wording promises encrypted offline access. Add an explicit, authenticated “Open last saved copy” path with captured-at and stale/partial status; never silently fall back because that hides authentication and freshness failures. Confidence: high.

9. **Archived and trashed items disappear with no way to view or restore them.** Decryption intentionally excludes them from projections, but Workstream 7 calls for distinct Archived and Trash filters and the README advertises archive writes. After archiving, the item simply vanishes. Add explicit filters/counts, read-only detail presentation, and unarchive only after its dedicated capability and tests pass. Confidence: high.

10. **Favorites are editable but not useful.** The edit sheet carries a Favorite toggle, while browse/search provides no Favorites scope, star affordance, or favorite ranking. This is invisible state and feels broken. Either surface Favorites coherently or postpone the toggle. Confidence: high.

11. **Write conflict and ambiguity feedback is too transient and generic.** `writeError` is a single app-level string; the main browser does not provide a durable conflict-resolution surface or item-scoped retry/reconcile workflow. A password manager must say whether a write definitely failed, may have succeeded, or conflicted, and should retain the draft until resolved. Confidence: medium-high.

12. **Selection can point at an item no longer in the current filtered result.** Changing the search query does not clear or reconcile `selection`, so the detail pane may continue showing an item hidden from the list. Scope changes clear selection, but query changes and post-sync removals do not. Clear selection when it is no longer present, while avoiding unwanted churn during incremental updates. Confidence: high.

13. **Per-vault lock leaves site icons from that vault in memory and on screen.** The row lock button calls `appModel.lock(account)` but does not clear or partition `SiteIconStore`; only Lock All and automatic lock call `siteIcons.clear()`. In a multi-vault session, icons derived solely from the closed vault can remain cached. Key icon storage by account and clear only that account, or conservatively clear all icons on any vault lock. Confidence: high.

14. **Quick Search can retain a stale in-memory item snapshot after a vault changes.** Items are copied into `QuickSearchPanelModel` only when the panel is presented. If sync, lock-one-vault, or hydration changes occur while the non-deactivating floating panel remains open, its rows do not update. Locking the last vault dismisses it, but locking one of several does not remove that vault’s copied projections. Dismiss or live-update the panel on every relevant session generation change. Confidence: high.

15. **Account removal/logout is absent from the visible interface.** There is Add Account and Lock, but no clear remove, logout, rename, or reconnect action. A user cannot recover cleanly from a wrong server/account except by unspecified external cleanup, despite the locked-shell copy telling them to “add the account again.” Add account management with explicit cache/credential deletion semantics and confirmation. Confidence: high.

16. **Adding the same provider/account has unclear duplicate and replacement behavior.** Vaultwarden uses a primary singleton identity; Proton also uses one fixed identity; 1Password derives identity from the account UUID. The UI does not explain whether adding again reconnects, replaces, or duplicates. Present existing-account detection and a deliberate reconnect/update flow. Confidence: medium-high.

17. **Unsupported item types degrade into generic rows rather than useful read-only views.** SSH keys are specifically claimed in README text, but the shared category has no SSH-key case; Proton and 1Password map SSH keys to unsupported, and Vaultwarden detail handling does not expose a purpose-built SSH-key surface. Preserve safe generic rendering, but correct the claim and add category-specific read-only rendering only with leakage-safe tests. Confidence: high.

18. **The empty-state recovery copy is misleading.** “If the unlock prompt doesn't appear, add the account again to rebuild it” suggests duplicate account creation instead of a reconnect/repair action and gives no reason or safe recovery path. Replace it with account-scoped diagnostics and recovery. Confidence: high.

### P1 — Performance and responsiveness

19. **Search runs synchronously on the main actor on every keystroke.** Both browser search and Quick Search linearly scan arrays with localized case-insensitive substring comparisons, including multiple arrays per item. This conflicts directly with the architecture requirement that search computation complete off-main and with the 100,000-item/250 ms budget. Build a bounded, normalized in-memory index off-main, debounce publication, cancel stale queries, and measure keystroke-to-render separately. Confidence: high.

20. **The aggregate item list is rebuilt and sorted on every access.** `AppModel.items` flattens and sorts every open vault each time SwiftUI evaluates it; `filteredItems`, the empty detail, and other view properties can invoke it repeatedly in one render. Cache sorted projections by scope/session generation and update incrementally. Confidence: high.

21. **Quick Search displays every item for an empty query.** Opening the panel with 100,000 items constructs a `List` over the full corpus and `results` recomputes filtering on access. Show recent/favorite items or a bounded top set before typing, cap rendered results (for example 50–100), and compute ranked matches in the index. Confidence: high.

22. **Search behavior is below the specified feature contract.** It offers only substring matching. The plan calls for accent/case normalization, prefix matching, quoted terms, deterministic ranking, and generated 1k/10k/100k corpora. Share one search engine between browser and Quick Search so behavior and performance do not drift. Confidence: high.

23. **Item rows can initiate hundreds of icon tasks and requests while scrolling.** Even with host deduplication and a 500-image cap, enabling icons in a large vault may cause a burst of concurrent network work and main-actor image decoding/publication. Add a small concurrency limit, cancellation for rows leaving the viewport, response MIME/dimension checks, and an account-scoped cache. Confidence: medium-high.

24. **Icon byte accumulation is byte-by-byte.** `URLSession.AsyncBytes` appends one byte at a time to `Data`, which is inefficient for up to 256 KiB across many icons. Consume chunks or use a bounded delegate/stream buffer. Confidence: medium.

25. **Group derivation repeatedly scans every item and sorts on render.** `VaultSlot.groups` rebuilds dictionaries across all items, and SwiftUI calls it from disclosure visibility, expansion content, and title lookup. Cache groups when projections publish. Confidence: high.

26. **There is no user-visible performance/freshness distinction between loading cache, decrypting, indexing, fetching secrets, and syncing.** A single spinner makes a multi-minute CLI refresh look hung. Expose staged progress and let an already-open cached list remain usable during refresh. Confidence: high.

### P2 — macOS interface, accessibility, and aesthetics

27. **The app has two visual personalities.** The empty shell uses a branded dark gradient and large rounded typography; the main browser falls back almost entirely to default `NavigationSplitView`, `List`, and toolbar chrome. Carry a restrained visual system—spacing, materials, accent, icon treatment, empty states, and status language—through the unlocked app without fighting macOS conventions. Confidence: high from code; requires real visual review.

28. **The default window is cramped for a three-column password manager.** `820×560` leaves roughly 230 points for the sidebar and then squeezes list/detail. Raise the ideal/default size, define sensible minimum widths for all three columns, and test narrow-window collapse behavior. Confidence: medium; requires screenshots on macOS.

29. **Detail fields lack grouping and action hierarchy.** Every field is a label/value/divider sequence. Cards, identities, notes, login credentials, custom fields, and security metadata need sections and context-sensitive actions. Use native grouped cards or inset sections, keep copy/reveal controls consistently aligned, and pin common actions where long notes do not push them away. Confidence: high.

30. **There is no copy confirmation or clipboard countdown.** Copy buttons are unlabeled icons with only a tooltip; users get no reassurance that a value copied or when it will disappear. Add a subtle transient “Copied — clears in 30s” state, never echoing the secret, and expose the countdown preference only at or below the security maximum. Confidence: high.

31. **Toolbar actions are dense and context is weak.** Add/Edit/Archive/Sync/Lock All are five equally weighted icons. Archive is destructive-adjacent and easy to mis-hit. Move secondary/destructive actions to item context menus or an overflow menu, keep Add and Sync prominent, and show keyboard shortcuts in menus. Confidence: medium-high.

32. **Quick Search lacks keyboard result navigation and selection styling.** Return always opens the first result; there is no explicit selected result, arrow-key navigation, Command-number action, copy shortcut, source-vault badge, category icon, or match highlighting. These are central to a keyboard-first product. Confidence: high.

33. **Quick Search is not actually global despite settings wording.** The settings row says “App shortcut Command-Shift-Space”; the implementation installs only an in-app command, so it works while VaultSquire is active, not system-wide. Call it an in-app shortcut until a reviewed global shortcut is implemented. Confidence: high.

34. **Settings claims configurability that the UI does not provide.** It says a configurable global shortcut and lock policy are enabled later, while auto-lock is already active at a hard-coded/default 15 minutes and no control is shown. Add a clear inactivity selector (with security-bounded values and “system lock always locks”), or accurately state the fixed behavior. Confidence: high.

35. **The lock timeout conflicts with the plan’s recommended five-minute default.** Code defaults to fifteen minutes; `PLAN.md` recommends five pending UX prototyping. This is not a controlling-document conflict because it remains listed as open, but it needs an explicit decision and consistent docs/UI before preview. Confidence: high.

36. **Provider onboarding is text-heavy and cramped at a fixed 420-point width.** Long privacy explanations, paths, symlink targets, account selection, errors, and origin/KDF approvals compete in one narrow sheet. Use provider cards or a two-step source picker, expandable security details, a wider adaptive sheet, and clear install/open-terminal help while keeping credential boundaries explicit. Confidence: high from code; visual confirmation required.

37. **Errors are embedded into sidebar subtitles.** A long CLI/network error replaces the account subtitle in a one-line row and becomes truncated; the user gets no structured remediation or retry beside the row. Use a status badge plus an accessible detail/retry popover or content-pane recovery view. Confidence: high.

38. **Disclosure and lock controls create small click targets.** The custom 12×12 disclosure control and borderless row lock are visually tidy but likely below comfortable pointer and accessibility target sizes. Expand hit regions while preserving alignment and verify Full Keyboard Access and VoiceOver. Confidence: medium-high.

39. **The site-icon privacy toggle is admirable but too verbose.** Keep the honest disclosure, but lead with one crisp sentence and put the threat-model detail under “Learn More.” The current block dominates the Privacy tab and makes the app feel like a policy document. Confidence: medium.

40. **No reduced-motion, increased-contrast, Dynamic Type, or localization review is evident.** Custom gradients, secondary/tertiary styles, small caption text, fixed window/sheet sizes, and English string interpolation all need accessibility and localization passes. Confidence: medium; requires macOS/manual evidence.

### P2 — Missing product capabilities

41. **Password generation is missing despite being in the first general-use scope.** Create/edit asks users to invent or paste a password. Add an offline generator with memorable/random modes, strength and policy controls, one-click fill, and no logging/persistence. This needs its own UX and statistical tests. Confidence: high.

42. **No duplicate-password, weak-password, reused-password, or breached-password health view exists.** A local-only “Watchtower”-style audit would add substantial value. Start with local reuse/weakness checks; any breach API must be opt-in or use a privacy-preserving prefix protocol with a separate threat review. Confidence: high as a valuable later feature, not current-gate work.

43. **No account/vault organization beyond folder/share scopes.** Missing conveniences include favorites, item-type filters, recently used/changed, sorting, tags, and pinned searches. These can remain memory-only and dramatically improve large-vault navigation. Confidence: high.

44. **No secure notes/card/identity editing surface.** `VaultItemEditView` is login-shaped. Either label Add as “Add Login” and document the limitation, or add type-specific drafts and lossless round trips only after provider mutation gates. Confidence: high.

45. **No duplicate detection or save-time URI normalization assistance.** Offer non-blocking warnings for same title/username/site, suspicious schemes, and visually confusable domains; never silently rewrite user data. Confidence: medium-high.

46. **No command palette or menu-bar workflow.** A reviewed optional menu-bar extra could provide Lock All, Quick Search, copied-secret countdown, and vault status without exposing item data. It must honor screen capture/accessibility and lock gates. Confidence: medium.

47. **No secure import/export, passkeys, attachments, autofill, or browser integration.** These are correctly deferred by the plan and should remain so until each threat model is accepted. Their absence should be made explicit in user-facing status rather than implied parity with full clients. Confidence: high.

## Delightful and differentiating ideas

These are product ideas, not implementation authorization.

1. **Squire Mode:** a compact, keyboard-driven panel where typing narrows results and pressing `⌘1`, `⌘2`, or `⌘3` copies username, password, or TOTP without opening the main window. Each action should show only a non-secret confirmation and immediately start the clipboard countdown.

2. **Vault Constellation:** an optional overview showing each open vault as a tasteful card with freshness, provider, item count, read/write capability, and lock state—no secret-derived content. It makes multi-vault status legible at a glance.

3. **Tiny heraldry:** extend the existing deterministic monograms into subtle provider-neutral “crests” generated locally from hostname hashes. They could be more distinctive than colored letters while leaking nothing and requiring no network.

4. **Polite shoulder-surfing mode:** a one-click presentation mode that hides usernames, URLs, titles, and icons until hovered or keyboard-focused, useful on calls or shared screens. It must not be described as protection against screen capture.

5. **Secret choreography:** after copy, animate only the copy icon into a small ring representing expiry; never animate or reveal the secret. The visual state becomes both delightful and security-informative.

6. **Contextual “why disabled?” explanations:** disabled provider actions can expose a concise reason (“1Password is read-only through the official CLI”) instead of feeling broken. This turns capability differences into trust-building clarity.

7. **Travel lock:** an intentionally stronger temporary posture that disables Touch ID quick unlock and purges provider snapshot keys until the next full authentication. This needs a careful recovery design and must never strand the user.

8. **Local security garden:** a calm, entirely local health page where reused/weak credentials become small plants needing attention. Keep the metaphor optional and always pair it with plain-language accessibility labels.

## Recommended implementation sequence

The following items are reasonable high-confidence candidates, but only within the controlling workstream order and one reviewable PR each:

1. Documentation truthfulness: reconcile README/status language and describe evidence levels (finding 1).
2. Correct misleading settings shortcut/lock copy (findings 33–35).
3. Clear site icons on any per-vault lock as an immediate privacy fix (finding 13), with a regression test where practical.
4. Preserve complete CLI snapshots by failing a refresh if any vault listing fails (finding 6), with Proton and 1Password tests.
5. Reconcile selection when filtering/sync removes the selected row (finding 12), with UI/model coverage.
6. Replace duplicate search implementations with a measured off-main index (findings 19–22) as a dedicated performance PR, not a cosmetic patch.
7. Design and implement reprompt, key rotation, and user-presence cache-key flows (findings 2–4) only as individually reviewed security changes with all required negative/cancellation/leakage tests.

Do not bundle visual redesign, new item types, or advanced product ideas into security fixes. Real-Mac screenshots, keyboard navigation, VoiceOver, Instruments, provider CLI, signing, and clean-install evidence remain mandatory before declaring those areas complete.

## Verification notes

- `./scripts/check-repository.sh` began successfully and confirmed version `0.1.0` plus the release block, then stopped because `python3` is unavailable in this Linux environment. This is an environment/tooling portability limitation; it is not evidence that the repository gate passed or that product tests failed.
- No macOS-only build, XCTest, UI test, signing, entitlement, sandbox, performance, visual, accessibility, CLI, or hardware result is claimed here.
- No production vault material, vendor credentials, external provider output, Keyguard source, or source-derived Keyguard design was inspected.
