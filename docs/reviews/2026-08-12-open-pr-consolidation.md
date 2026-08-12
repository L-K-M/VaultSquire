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

Nothing below is addressed by this consolidation. The first four are the
substantial ones, and all four were independently raised by more than one of
the review passes.

1. **Master-password reprompt is not enforced.** `requiresReprompt` is
   preserved on the wire model, but reveal, copy, edit and archive do not ask
   for fresh authentication. An open session satisfies operations the
   architecture says require re-verification.
2. **Key-rotation reauthentication is incomplete.** #29 stopped sync from
   absorbing rotated key material, which is the safe half. Detecting it,
   persisting `reauthenticationRequired`, invalidating quick unlock, and
   blocking secret operations until the user re-authenticates is not done.
   #30's `bootstrapChanged` detector is the complement to #29, not a
   replacement for it.
3. **CLI cache-envelope keys are not bound to user presence.** The snapshots
   omit secret values but still disclose account inventory, titles,
   usernames, addresses and vault names.
4. **CLI executable identity rests on path and self-reported version.** A
   replaced binary at an allowlisted path can claim an admitted version. Code
   signature, team identity, and designated requirement are not checked.
5. **Archived items cannot be browsed or restored.** Archive now confirms
   before acting and says where to restore from, but there is still no
   in-app archive view.
6. **No account removal or sign-out.**
7. **Quick Search results are a presentation-time snapshot** for anything the
   panel is not told about; a sync landing while it is open updates it, but
   the ranking is recomputed rather than incremental.
8. **The documented 10,000- and 100,000-item interaction budgets are
   unmeasured.** The scoped list and the panel's index are both bounded now,
   but neither has been measured on a Mac against those budgets.
9. **Real-provider compatibility is unproven.** Both CLI mappings are tested
   only through fake executors, and the Vaultwarden cross-client crypto
   differential is outstanding.

Findings 1–4 and 9 are release gates in
[`RELEASE_ELIGIBILITY.md`](../../RELEASE_ELIGIBILITY.md) and
[`SECURITY_AND_TESTING.md`](../../SECURITY_AND_TESTING.md); this document does
not change their status.

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
