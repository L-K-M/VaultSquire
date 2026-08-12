# Open pull request consolidation — 2026-08-12

Forty pull requests were open against `0c05294` at once, written by several
independent review passes that could not see each other's work. Many
implemented the same feature two or three times, several conflicted, and one
would have reverted security fixes already merged.

This document records what was taken, what was superseded, and what is still
open. It replaces the seven competing root-level `ANALYSIS.md` drafts and the
per-pass review files (`sol.md`, `opus.md`, `ds.md`, `k3.md`, `glm.md`) that
those pull requests each proposed adding to the repository root.

- Base: `0c05294`
- Environment: Linux. No Swift toolchain, so **nothing here has been
  compiled or tested.** Every judgement below is from reading code.
  Referential integrity of `project.pbxproj` was checked mechanically; the
  `macOS Product` CI lane is the executing gate.

## What the duplication looked like

| Feature | Pull requests | Kept |
|---|---|---|
| Password generator | #42, #61, #71 | #71 |
| Auto-lock timeout setting | #36, #60, #68 | #68 + grafts |
| Quick Search keyboard/polish | #40, #44, #46, #51, #62 | #46 + grafts |
| Browser selection correctness | #38, #56, #64 | #56 + grafts |
| Item detail copy behaviour | #34, #45, #50, #54 | #50 + #34 |
| Item row actions | #55, #59 | #55 + one graft |
| Archive confirmation | #43, #58 | combined |
| Review documents | #33, #37, #47, #48, #52, #66, #69, #72 | this file |

Seven of the eight document pull requests added a file called `ANALYSIS.md`,
so they conflicted with each other by construction.

## Defects found in the work that was kept

These were in the branches judged best, and are fixed here.

- **`let favorite: Bool = false`** (#70) does not compile. A `let` with a
  default value is excluded from the synthesized memberwise initializer, so
  the decryptor's `favorite: cipher.favorite` had no parameter to bind to.
- **Reveal and copy timers retained decrypted items** (#50). Both spawned
  unstructured Tasks that were never held or cancelled, each capturing a
  `View` struct whose stored `detail` is the fully decrypted item — so a
  sleeping timer kept an item's plaintext alive for thirty seconds after the
  view was gone and the vault was locked.
- **The offline snapshot was served when the provider refused** (#53). The
  fallback fired for every failure class, including a signed-out Proton CLI,
  a locked 1Password app, and a user pressing Deny on the authorization
  prompt. That makes the offline cache a way around the authorization gate.
- **Secret rows were text-selectable** (pre-existing; fixed by #34). A
  selection can be copied with the system's own ⌘C, straight past
  `ClipboardService` and therefore past the expiry, the clear-on-lock, and
  the concealed-type hints.
- **The row context menu decrypted every visible item** (#55, #59). Both
  resolved the decrypted detail inside the menu builder, which the list can
  evaluate during row construction rather than on right-click.
- **An open item lost its password after a sync** (#41). Hydration was keyed
  on the selection alone, so dropping the fetched secrets of the item already
  on screen never triggered a re-read.
- **A one-minute auto-lock could take two** (#68). The timeout became
  configurable but the poll interval stayed at a fixed minute.
- **The Quick Search panel kept a locked vault's data** (#46). `clear()` is
  the lock path but only reset the query, leaving items, results, titles and
  the open handler alive behind an invisible window.
- **The Quick Search key monitor was never removed** (#62). Installed in
  `init`, process-wide, one per controller.
- Smaller: the copy receipt asserted the clipboard had been cleared when
  `clearIfOwned` may deliberately not clear it; the one-time-code row
  combined its children for accessibility and made its copy button
  unreachable; hidden shortcut buttons were opacity-zero but hit-testable;
  the password shortcut would pick a card's security code.

## PR #30 — do not merge

#30 is a second, independent adversarial security review, branched from
`8bed416`, before #24, #25 and #29 merged. Roughly 60% of its value is
already on `main` or done better there. Merging it as a branch would:

- **revert #29.** Its `merge` still contains the two lines that let a sync
  adopt `profile.key`/`profile.privateKey` in place, which #29 (`14a076c`)
  replaced with an empty-slot-only guard. A hostile or rotated server could
  re-key the stored snapshot again.
- **break Release builds.** It wraps `VaultwardenWriteService` in `#if DEBUG`
  while `VaultwardenAccountService` calls it unconditionally. DEBUG CI would
  stay green.
- **disable all Vaultwarden writes** and hide both CLI providers behind a
  provider gate.
- **break Touch ID on every unsigned build**, by deleting the two-keychain
  fallback loop that exists because the Data Protection Keychain needs an
  entitlement a locally built app does not carry.
- **break the vault cache on every unsigned build**, by sourcing the cache
  directory only from an app-group container.
- **make sync take tens of seconds**, by draining the response one `UInt8` at
  a time through an `AsyncSequence`.
- **brick sync on one malformed cipher date**, by making a per-item decode
  failure fail the whole batch.
- **deadlock writes permanently**: its sync-success generation bump makes an
  in-flight write return before clearing `isWriting`, and every later write
  is gated on that flag.

It also contains roughly ten genuinely new hardening changes `main` never
touched — CLI process hardening, transport path canonicalization and TLS
classification, token refresher, TOTP parser bounds, icon SSRF and
decompression limits, a `securityStamp` rotation detector, a durable
`reauthenticationRequired` marker, session-generation saturation, lock
ordering with `LAContext` invalidation, and fail-closed descriptor decoding.

**Recommendation:** close #30 as a branch and re-raise those ten as their own
pull requests against current `main`, each with the macOS evidence its change
needs. They are not included here: grafting ten delicate security changes
blind, in an environment with no compiler, into an already large consolidation
is exactly how a security-critical merge goes wrong.

## Still open

The union of the distinct findings across all eight review documents, with the
ones this branch closes removed. Each was checked against the code rather than
taken from a document's own status table — every one of those tables marked
work "done" that was only ever an open pull request against the same base.

### Security invariants

- **Master-password reprompt is not enforced.** `requiresReprompt` is
  preserved on the wire model, but reveal, copy, edit and archive do not ask
  for fresh authentication. An open session satisfies operations the
  architecture says require re-verification.
- **Key-rotation reauthentication is incomplete.** #29 stopped sync from
  absorbing rotated key material, which is the safe half. Detecting it,
  persisting `reauthenticationRequired`, invalidating quick unlock, and
  blocking secret operations until the user re-authenticates is not done.
  #30's `bootstrapChanged` detector is the complement to #29, not a
  replacement for it.
- **CLI cache-envelope keys are not bound to user presence.** The snapshots
  omit secret values but still disclose account inventory, titles, usernames,
  addresses and vault names.
- **CLI executable identity rests on path and self-reported version.** A
  replaced binary at an allowlisted path can claim an admitted version. Code
  signature, team identity, and designated requirement are not checked.
- **CLI stdout/stderr streams are not actually bounded.** Both
  `AsyncStream`s in `CLIProcessExecutor` are created with
  `bufferingPolicy: .unbounded`; stdout is capped only once chunks reach the
  collector and stderr has no byte cap, so a replaced CLI can enqueue faster
  than the actor drains.
- **`sessionExpired` leaves the vault open.** A revoked refresh token is
  recorded as a sync or write error while the decrypted vault stays on
  screen and further doomed operations remain available.
- **Local persistence failure is reported as success.** A failed rotated
  refresh-token replacement and a failed `vaultCache.save` are both ignored
  while the fresh snapshot is returned as success, so the UI shows data that
  was never durably sealed.
- **Untested CLI versions sit in the production allowlists**, with in-code
  comments saying none was exercised against a live CLI. Empty is the safe
  pre-evidence state.
- **Accessibility identifiers embed vault content** — `reveal-\(field.label)`
  and `open-uri-\(field.label)`, where the label can be a user's custom-field
  name. Vault-derived strings reach the accessibility tree. Not fixed here
  because the identifiers are load-bearing for UI tests and the replacement
  needs to be chosen with those in hand.
- **`.mouseMoved` counts as activity** for the inactivity clock, so ambient
  pointer motion over the window defeats auto-lock. That is a policy
  decision, not only the performance question it looks like.

### Correctness

- **Vaultwarden `collections` are never decoded.** An organization item filed
  only under a collection gets empty `groupingLabels` and is invisible to
  sidebar grouping, though `PLAN.md` lists collections as in scope.
- **`openCredentialFreeVaults()` overrides a deliberate lock** — it runs on
  every successful unlock, so a CLI vault the user locked on purpose is
  reopened by an unrelated Vaultwarden unlock.
- **A second Vaultwarden account silently replaces the first**, because
  credentials are keyed to `AccountID.vaultwardenPrimary`.
- **Site-icon fetches follow redirects with a default delegate**, so a site
  can redirect its favicon to an aggregator — contradicting the README's
  promise that no icon service is involved. Decoding also runs on the main
  actor, and a small file can still carry huge dimensions.
- **`SiteIconStore` marks a host attempted before the await**, so one
  transient failure disables that icon for the session, and it has no
  eviction at its cap, so once full no new host ever loads.
- **Transport failure claims the change was not saved**, but a connection can
  fail after the server commits. Pre-send and ambiguous failures need to be
  distinguished.
- **Empty CLI vaults never appear in the sidebar**, because CLI-provider
  groups are derived from items alone.
- **`VaultSession`/`SessionState` is a fully tested state machine that
  production code does not use.** Wire it in or delete it.
- **Archived and trashed items cannot be browsed or restored.** Archiving now
  confirms and says where to restore from, but `restoreItem` is unused and
  there is no Archived filter.
- **No account removal or sign-out.** `AccountDescriptorStore.remove` exists
  and is dead code; nothing deletes tokens, caches, or biometric envelopes.
- **Initial sign-in reports success without a complete first snapshot**, so a
  first unlock can present an empty vault under "Account Added".

### Performance and scale

- **The documented 10,000- and 100,000-item interaction budgets are
  unmeasured.** The scoped list is cached and the panel is capped now, but
  neither has been measured on a Mac against those budgets.
- **`detail(for:)` is called from the view body** and linearly scans the
  cipher array, decrypting per field on every render. It should be memoised
  on item, generation and hydration state.
- **No revision-gated sync.** Every sync re-downloads and rewrites the whole
  sealed file; the CLI providers run one process per vault per refresh and
  re-probe the CLI version before every on-demand secret fetch.
- **The TOTP row recomputes the full HMAC once a second** when the code
  changes once a period; the countdown and the code should be separate.
- **The whole-file encrypted store** is JSON plus ChaCha20-Poly1305 with no
  row-level updates and no WAL, migration, or crash evidence. Workstream 5
  is not done.

### Claims

- **Real-provider compatibility is unproven.** Both CLI mappings are tested
  only through fake executors, and the Vaultwarden cross-client crypto
  differential is outstanding.
- **Argon2id fails closed correctly**, but "implemented end to end" hides a
  common Vaultwarden compatibility boundary.
- **Account email is persisted to `UserDefaults`** while the security plan
  treats account identifiers as high sensitivity. Needs an explicit
  reconciliation in a controlling document.

The security-invariant items and the unproven-compatibility item are release
gates in [`RELEASE_ELIGIBILITY.md`](../../RELEASE_ELIGIBILITY.md) and
[`SECURITY_AND_TESTING.md`](../../SECURITY_AND_TESTING.md); this document does
not change their status.

## Definition of done, carried forward

The best paragraph in the eight documents, kept because every one of their
status tables violated it: "code exists", "a unit test over a fake passed",
and "an open PR is green" are not synonymous with supported or done. Each of
the eight review passes marked its own open pull requests as completed work.
None of them was merged.

## What needs a Mac

Everything in this consolidation is unbuilt. In particular:

- `MainActor.assumeIsolated` in the auto-lock input monitor and in the Quick
  Search key monitor traps if the callback is ever delivered off the main
  thread. Both are local `NSEvent` monitors, which are documented to run on
  the main thread as part of event dispatch, and the pattern is already used
  in `AutoLockController` — but it is a trap, not a warning, so it should be
  exercised.
- Whether `.contextMenu` builds its content eagerly per row. The menu was
  rewritten to read only projection and capability data so that it does not
  matter, but the assumption behind that rewrite is worth confirming.
- `WindowGroup` replacing `Window`: File ▸ New Window should not appear,
  because `CommandGroup(replacing: .newItem)` already replaces that group.
- The Steam Guard code path has no published test vectors; the tests assert
  shape, alphabet membership, window stability and fail-closed parsing, not a
  known-answer.
