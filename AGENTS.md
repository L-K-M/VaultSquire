# VaultSquire agent and contributor notes

VaultSquire is a planned native macOS password-manager client for self-hosted
Vaultwarden and, later, Proton Pass through the official user-installed CLI.
This history-isolated repository contains research, governance, the Workstream 1
native-shell implementation, the Workstream 2 domain/session/provider contracts,
and the Workstream 3 Vaultwarden cryptographic harness. It has no supported
release, no network or persistence layer, and no wired-up provider
implementation.

## Read first

Read the documents in the order defined by [README.md](README.md):

1. [PLAN.md](PLAN.md) controls product scope and sequence.
2. [SECURITY_AND_TESTING.md](SECURITY_AND_TESTING.md) controls security invariants and release gates.
3. [ARCHITECTURE.md](ARCHITECTURE.md) controls component and data boundaries.
4. The implementation and provider reports are subordinate evidence.
5. [KEYGUARD_FORK_ASSESSMENT.md](KEYGUARD_FORK_ASSESSMENT.md) is a binding source-isolation decision.

Conflicts among the controlling documents block implementation. Do not silently
select the less restrictive rule.

## Implementation gate

`IMPLEMENTATION_CONTEXT.md` records the accepted history-isolation attestation,
and `WORKSTREAM_0.md` records the governance/evidence exit. Application work may
begin only with Workstream 1 and must follow the sequential PR gates in
`DELIVERY.md`. A dependency remains prohibited until its own assessment and
adoption gate pass. Superseded planning history is never an approved coding
input.

Do not inspect or use earlier Keyguard-derived commits as implementation context.
Do not include a Keyguard checkout, source-derived notes, or source-level
comparisons in prompts, fixtures, reviews, or build environments.

## Source hygiene

- Do not copy, translate, port, adapt, or mechanically reproduce Keyguard code,
  architecture, tests, strings, assets, database designs, or distinctive UI.
- Bitwarden, Vaultwarden, and Proton sources are pinned protocol evidence, not
  implementation source. Do not copy their expression into product code.
- Proton and 1Password integration is through their official user-installed CLIs
  only. Do not implement either vendor's private API, cryptography, or session
  model. VaultSquire never collects a Proton or 1Password credential.
- Every future dependency needs exact version, origin, checksum, license,
  transitive inventory, owner, update policy, and reason.
- Use synthetic accounts and secrets only. Never use, commit, upload, or paste
  production vault data, tokens, CLI output, databases, logs, or support bundles.

## Security invariants

- The master password is never persisted, logged, normalized, or sent raw.
- Unknown cryptographic forms fail closed while their ciphertext is preserved.
- Plaintext vault content never intentionally reaches SQLite pages, journals,
  temporary files, preferences, logs, diagnostics, restoration, or search indexes.
- Lock invalidates the session generation before cancellation and cleanup, so
  late asynchronous work cannot republish decrypted state.
- CLI secrets never travel in argv, environment variables, logs, or plaintext
  files. Every provider CLI runs through the one shared no-shell executor,
  whose environment is an allowlist rather than a filter.
- Writes remain disabled until their provider-specific conflict and secret-input
  contracts have positive, negative, cancellation, ambiguity, and leakage tests.

## Current verification

The current Linux environment can verify only documentation and repository
hygiene. A native Apple Silicon Mac with the pinned Xcode can additionally run
the commands recorded in `WORKSTREAM_1.md`:

- links and Markdown structure;
- JSON/YAML syntax;
- whitespace;
- presence of governance files;
- absence of tracked IDE state and secret material;
- Swift build, XCTest, UI-test, signing, entitlement, and architecture checks on
  the macOS environment only.

Do not claim macOS, accessibility, hardware-performance, signing-identity,
notarization, or process-sandbox results from Linux. Each CI job must have the
reproducible local command it runs.

## Repository automation

- `repository-hygiene.yml` validates governance and rejects tracked local/secret files.
- `macos-product.yml` is reusable by the guarded release workflow and runs the
  same `scripts/ci.sh` product gate used locally.
- `release.yml` is signed-only future infrastructure. It remains blocked until
  all pre-artifact candidate gates pass and its exact source commit is approved;
  artifact-dependent gates then apply to the restricted draft, which still may
  not be distributed or published. See `CICD.md`.
- `zai-code-review.yml` is explicit opt-in through the `glm-review` label. Add
  that label only when the PR diff may be sent to Z.ai. Never label embargoed
  security, licensing, provenance, or contamination work for external review.
- Dependabot currently covers GitHub Actions only. Add Swift coverage after a
  real dependency manifest exists.
- `.claude/settings.json` enables the shared Claude cloud MCP tools but does not
  supersede the clean-room and secret-handling rules above.

Preserve `media-sources/icon.png` as the canonical source artwork. Derived
assets exist and are recorded in `ICON_PROVENANCE.md` (derivation tool,
command, and per-file hashes); its small-size visual review gate remains open,
and any regeneration must refresh that record.

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Writing the code is not finishing the task. A task is finished when
  its changes are merged to main through a PR that passed CI and review,
  or when the user explicitly accepts a different end state.
- Start every task on current code. Fetch first, then cut the task
  branch from origin/main — never from a stale local branch or an old
  checkout. To continue existing work, rebase or merge the latest
  origin/main into it before editing. Never overwrite existing work to
  update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch cut from the latest origin/main and open a PR
   against main before reporting the task as done.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Reviewer context limits

The automated PR reviewer does not see the user's original prompt or
conversation. It may suggest changes that go against or beyond what the
user asked for. Do not implement such suggestions. Note each conflict and
report it to the user at the end of the thread.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Ending a task

- A task ends with its changes merged to main — not with code written,
  and not with a PR merely opened. An open PR is work in progress:
  monitor CI on the latest commit, address review findings per the
  stopping rules, and merge once the criteria are met.
- Never finish with uncommitted changes or unpushed commits in the
  worktree. Commit, push, and open or update the PR first.
- If a step is impossible (missing push access, CI failure, reviewer
  outage), report the exact blocker instead. Never present unreviewed or
  unmerged work as finished.
- Before finishing, confirm: the requested behavior is implemented
  without unrelated changes; relevant checks pass on the latest code;
  important review findings are addressed or rejected with reasons;
  deferred suggestions, remaining risks, and validation gaps are
  disclosed.
- The final response states where the work stands: branch, PR, CI
  status, review rounds completed, and whether it is merged.

<!-- shared-rules:end -->

