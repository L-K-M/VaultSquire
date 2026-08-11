# ANALYSIS — VaultSquire Working Review Document

This is the living review document for VaultSquire's UX, performance, and
feature surface. It consolidates the K3 review (`k3.md`, commit `0c05294`) and
absorbs any earlier review notes. Completed work is recorded in §1 and removed
from the actionable lists; everything in §2–§6 is open work, ordered roughly
by value within each section.

**Method note.** K3 was a static review performed on Linux. Items marked
*[needs macOS verification]* assert something about runtime behavior that only
a Mac can confirm. The `macOS Product` CI lane (`scripts/ci.sh`) is the
executing gate for all code changes.

---

## 1. Completed (record)

| ID | Change | PR |
|---|---|---|
| B1 | Quick Search selection no longer dropped when the scope changes | #56 |
| B2 | Quick Search jump handles `.group` scopes (narrows to owning vault) | #56 |
| B5 | Toolbar "last synced" text re-evaluates on a timeline | #56 |
| P1 | Item list sorted once per render, not twice | #56 |
| B3 | Stale write error no longer appears in a fresh edit sheet | #57 |
| B4 | Archive asks for confirmation, naming the item | #58 |
| M6 | Item-row context menu: copy username/password/TOTP, open site | #59 |
| B6/M2 | Auto-lock timeout setting (Never/1/5/15/30/60 min), live re-arm | #60 |
| M3 | Password generator (CSPRNG, unbiased, class coverage guaranteed) | #61 |
| M4 | Password reveal toggle in the edit sheet | #61 |
| U1 | Quick Search keyboard navigation (arrows + Return, field keeps focus) | #62 |

Also completed before this review (see `docs/security-review/2026-08-11-adversarial-review.md`):
16 adversarial-review remediations including PBKDF2 floor 100k, no silent
key rotation on sync, CLI cancellation on lock, URI scheme allowlist.

---

## 2. Open bugs and correctness items

- **B7 — Quick Search results are a presentation-time snapshot.** A sync
  landing while the panel is open isn't reflected; an archived item is still
  offered. Make `results` track the data source while the panel is up.
  *Low.*
- **B8 — `SiteIconStore` has no eviction at its 500-icon cap.** New hosts stop
  loading for the rest of the session. Add LRU or halve-and-continue. *Low.*
- **B9 — Failed unlock clears the typed master password.** Conservative but
  annoying; if kept, at least guarantee the field keeps focus.
  *[needs macOS verification]* *Low.*
- **B10 — `NSApp.activate()` may not raise the app** for Quick Search on
  recent macOS; consider `activate(ignoringOtherApps:)` after interactive
  testing. *[needs macOS verification]*
- **B11 — Latent: edit-sheet auto-close watches the global `isWriting`.**
  Safe today only because every write trigger is disabled while writing; a
  per-write token would make it robust against future write paths. *Low.*
- **B12 — `VaultItemProjection` whole-value equality trap.** Selection is
  keyed by `id` today; anything keying on the full value breaks across syncs.
  Code-comment only.

## 3. Open performance items (measure on hardware first)

- **P2 — `AppModel.items`/`allOpenItems` re-sort on every access.** Memoize
  the merged sorted list; invalidate on session/item changes.
- **P3 — Post-sync projection rebuild decrypts every cipher on the main
  actor** (inside `mutate`). Compute projections off-actor, then swap in.
  Most likely user-visible stall on large vaults.
- **P4 — `detail(for:)` re-decrypts the selected item every browser render.**
  Cache per `(itemID, generation)`.
- **P5 — `VaultSlot.groups` recomputed per sidebar render.** Memoize with P2.
- **P6 — Locale-aware substring matching per keystroke.** Precompute
  lowercased search keys if profiling ever shows it.

## 4. Open feature gaps

**Blocked on gates:**
- **M1 — Global Quick Search hotkey.** Adoption gated by
  `docs/dependencies/keyboard-shortcuts.md`.
- **M14 — Argon2id unlock.** Fails closed correctly; gated by
  `docs/dependencies/argon2.md`.

**Straightforward, high value:**
- **M5 — Favorites are write-only.** Surface `favorite` on
  `VaultItemProjection`; star badge, Favorites section/filter.
- **M7 — Keyboard copy shortcuts** (⌘⇧C password, ⌘⇧U username) for the
  selected item; natural follow-up now that the context menu exists.
- **M10 — Item metadata**: created/modified dates, password history (cipher
  model already carries both).
- **M8 — Sort options** (recently used/modified; needs `revisionDate` on
  projections).
- **M9 — Category filter** (logins/cards/notes/identities).

**Workstream-gated (see `DELIVERY.md`):**
- **M11 — Trash/restore and unarchive** (write-gate territory).
- **M12 — Create/edit beyond logins** (notes, cards, identities).
- **M13 — Multiple Vaultwarden accounts** (`vaultwardenPrimary` is a fixed id
  by design until that workstream).
- **M19 — Attachments**, **M20 — SSH-key item type**.

**Ideas needing a decision first:**
- **M15 — Menu-bar presence** (lock state, quick search, lock now).
- **M16 — Password strength meter** (local heuristic, no dependency).
- **M17 — HIBP breach check** — only k-anonymity design is compatible with
  this repo's privacy posture; document the tradeoff before any code.
- **M18 — Local audit view**: reused/old/weak passwords, fully offline.
- **M21 — Auto-type.** Large; own threat model.

## 5. Open UX / aesthetic increments

- **U2 — Quick Search rows**: add item icons + vault badges (reuse
  `ItemIconView` and the capsule from the browser rows).
- **U3 — Wrong-password feedback**: subtle shake + haptic + field refocus.
  *[needs macOS verification]*
- **U4 — Auto-conceal revealed secrets** after ~30 s and on window resign.
- **U5 — List-row badges** (TOTP present, favorite) once M5 lands.
- **U6 — Empty-detail pane** should teach the three keyboard shortcuts.
- **U7 — Menu-bar commands** for selection actions (needs `FocusedValue`).
- **U8 — Sidebar failure rows**: `.help(message)` tooltip (messages truncate
  at one line today).
- **U9 — Retry affordance** on failed vault rows.
- **A1 — Unlock transition** (200 ms cross-fade + rise).
- **A2 — TOTP countdown ring** replacing the seconds text.
- **A3 — Detail header banner** tinted by the item's hue.
- **A4 — Per-provider tint** on sidebar lock icons (hues, not brand assets).
- **A5 — Quick Search chrome**: rounded corners, softer shadow, more vibrancy.
- **A6 — Monogram depth**: barely-there vertical gradient on the tile.
- **A7 — Owned accent color** instead of system blue.

## 6. Delight ideas (pick selectively)

- **D1 — Screen-sharing concealment**: mask revealed secrets/TOTP when the
  window is captured (`NSWindow.sharingType` / ScreenCaptureKit). Very on-brand
  for this repo.
- **D2 — ⌘⇧C in Quick Search copies the result's password** without opening it
  (pairs with M7; the fastest possible credential path).
- **D3 — Haptics on lock/unlock** (`NSHapticFeedbackManager`).
- **D4 — "Time to crack" line** under generated passwords (pairs with M16).
- **D5 — Password-age nudge** on the detail pane (with M10).
- **D6 — Next-code preview** in the last 5 s of a TOTP window.
- **D7 — Teachable-moment toast** after an inactivity auto-lock.

## 7. Strengths to preserve

- Single-reviewed-place security controls (clipboard ownership, URI
  confirmation, CLI executor allowlist, capability gating in the use-case
  layer, KDF floor/ceiling, generation-checked async publication).
- The named-residuals culture in security reviews (R5–R8 pattern).
- Deterministic monogram tiles (written-out FNV-1a; stable across launches).
- Comments that record *why*, including past traps.
- Leakage/fuzz/cancellation/capability test surface; consistent accessibility
  identifiers.
