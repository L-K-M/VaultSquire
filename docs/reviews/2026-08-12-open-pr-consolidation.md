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

**Disposition:** #30 was closed as a branch and its genuinely-new work re-raised
as five pull requests, listed below. None of it was folded into this
consolidation: grafting ten delicate security changes blind, in an environment
with no compiler, into an already large branch is exactly how a
security-critical merge goes wrong.

### How it was extracted

Grouped by review surface rather than one pull request per change — the reviewer
for CLI process handling is not the reviewer for icon fetching. Ordered by value
over risk. All five are open:

| | Extraction | Pull request | Based on |
|---|---|---|---|
| 1 | Bound the CLI process streams | [#74](https://github.com/L-K-M/VaultSquire/pull/74) | `main` |
| 2 | Harden the icon fetch | [#77](https://github.com/L-K-M/VaultSquire/pull/77) | this branch |
| 3 | Fail closed on corrupt stored descriptors | [#75](https://github.com/L-K-M/VaultSquire/pull/75) | `main` |
| 4 | Harden the transport | [#76](https://github.com/L-K-M/VaultSquire/pull/76) | `main` |
| 5 | Bound TOTP input | [#78](https://github.com/L-K-M/VaultSquire/pull/78) | this branch |

The first three touch files this consolidation does not, so they go to `main`
directly and can land in any order. The last two touch files this branch
rewrote — the icon store's publishing and the Steam Guard seed path — so they
are written on top of it and need it merged first.

None of the five is compiled: the `macOS Product` lane is the first build for
each. Each states its own unverified assumptions.

The plan they were written from follows, kept because it records what each one
was meant to contain and what it was meant to leave behind.

1. **Bound the CLI process streams.** `CLIProcessExecutor` counts bytes before
   they enter the async drain and terminates the child on the bound, and the
   child environment becomes a closed enum rather than a dictionary callers can
   extend. This closes the open finding that the streams are documented as
   bounded and are created `.unbounded`. One file plus tests, no conflict with
   anything merged since.
2. **Harden the icon fetch.** Reject IP literals and local-only suffixes before
   any request, and inspect image metadata with ImageIO for implausible
   dimensions or pixel counts before asking AppKit to decode. Add a store
   generation and cancel in-flight fetches on lock so a late response cannot
   repopulate. This is the one feature that sends anything vault-derived off the
   device, so it earns its own review. Must be written on top of the icon
   publish-batching on this branch, not cherry-picked over it.
3. **Fail closed on corrupt stored descriptors.** Unreadable preferences must
   not be treated as an empty account list and overwritten. Small.
4. **Harden the transport.** Path canonicalization, an explicit redirect policy,
   and an `expectedContentLength` pre-check against the response bound. Take the
   policy; do **not** take #30's replacement of `data(for:)` with a per-byte
   `AsyncBytes` drain, which makes a realistic sync take tens of seconds.
5. **Bound TOTP input.** Cap seed length before URL parsing and uppercasing, and
   avoid the trapping `Double(UInt64.max)` conversion boundary. Do not carry
   #30's comment claiming the previous base32 accumulator crashed: Swift's `<<`
   on a fixed-width integer discards high bits rather than trapping.

Two items need a decision before they are worth extracting:

- **The session-generation hardening** — saturating the counter instead of
  wrapping, and making a durable reauthentication requirement block quick unlock
  as well as password unlock — is correct, but `VaultSession` is referenced by
  nothing except its own tests. Hardening it changes no runtime behaviour. It
  belongs with the decision to wire that actor in as the single authority or
  delete it, not shipped alone as a security fix that reaches no user.
- **The `reauthenticationRequired` marker and the `securityStamp` rotation
  detector** are the complement to the merged no-silent-rotation guard, and are
  the most valuable thing in #30. They are also not an extraction: a durable
  marker, quick-unlock invalidation, and refusing secret operations until a
  complete reauthentication is a design-first transaction with its own crash and
  cancellation tests.

Do not extract, in any grouping: the sync-success generation bump (it wedges
`isWriting` for the process lifetime), the `#if DEBUG` around the write service,
the single-query Keychain change, the app-group-only cache directory, the
per-byte transport drain, the per-cipher strict date decode, the `_exit` on a
failed `setrlimit`, or the duplicate lock observers in the app delegate.

## Still open

The union of every distinct finding across all eight review documents — including
the product, interaction, visual, accessibility and delight ideas that are not
defects — is in
[`2026-08-12-consolidated-backlog.md`](2026-08-12-consolidated-backlog.md),
which replaces the seven competing `ANALYSIS.md` drafts and the five per-pass
root files.

The headline items it leaves open, none of which this consolidation addresses:
master-password reprompt is not enforced; key-rotation reauthentication is
incomplete; CLI cache keys are not bound to user presence; CLI executable
identity is not authenticated; the CLI process queues are not actually bounded;
a revoked session leaves the vault open; local persistence failures are reported
as network success; there is no logout or account removal; and real-provider
compatibility is unproven. Those are release gates in
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
