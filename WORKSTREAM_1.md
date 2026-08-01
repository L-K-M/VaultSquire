# Workstream 1 Native Shell And Performance Record

- Status: code merged to `main`; exit evidence incomplete and still owed
- Owner: `L-K-M`
- Started: 2026-07-31
- Scope: native shell, diagnostics, performance fixtures, and process/sandbox
  feasibility only

Workstream 1 does not implement an account, provider, vault, credential field,
database, global shortcut registration, or application write. No real vault or
account data is valid test input.

## Implemented Surface

- One SwiftUI application window with a locked-only state and disabled state
  restoration.
- Settings and an AppKit `NSPanel` Quick Search spike with keyboard dismissal,
  all-Spaces/full-screen auxiliary behavior, and memory-only query text.
- Fixed-enum local logging with no metadata parameter and signpost intervals for
  launch and panel presentation.
- An actor-isolated process probe that uses an absolute, symlink-resolved
  executable URL, no shell, a fixed environment, null stdin, bounded
  stdout/stderr byte counting, timeout, and cancellation termination.
  Termination escalates from `SIGTERM` to `SIGKILL` after a grace period, and the
  readers are force-closed after their own grace period so a surviving descendant
  holding a pipe write end cannot make the probe hang. That case is reported as a
  distinct `outputRemainedOpen` failure rather than as a clean result.
- A sandbox-only Settings tab for selecting an executable and optional existing
  CLI session directory through `NSOpenPanel`. It can run only startup or a
  candidate non-interactive `info` subcommand, and never displays or retains raw
  output. See the limitation recorded under Process Feasibility Procedure: the
  selected session directory is not passed to the CLI, so this harness does not
  yet exercise session or keyring discovery.
- Unit, UI, launch, and signpost performance fixtures. The warm Quick Search
  fixture lives in the UI test target so it drives the real presentation path
  (which is what opens the signpost interval) and measures a Release build that
  was not compiled with testability.
- Reproducible Apple Silicon build, ad-hoc Hardened Runtime signing, entitlement,
  linked-image, and architecture inspection scripts.

No third-party application package is adopted. The global shortcut remains an
in-app menu shortcut until the candidate comparison and manual interaction gate
pass. Generated app icons remain blocked by `ICON_PROVENANCE.md`.

## Toolchain Pin

| Property | Required value | Observed value |
|---|---|---|
| Runner | GitHub-hosted Apple Silicon `macos-15` | macOS `15.7.7`, `arm64` in workflow run `30696406614` |
| Xcode | `26.3` at `/Applications/Xcode_26.3.app/Contents/Developer` | `26.3` build `17C529` |
| Swift compiler build | Emitted by `xcrun swiftc --version` | Apple Swift `6.2.4` (`swiftlang-6.2.4.1.4`, Clang `1700.6.4.2`) |
| macOS SDK version/build | Emitted by `xcrun --sdk macosx` | `26.2` build `25C58` |
| Deployment target | macOS `14.0` | Confirmed by the Release compiler target and binary build |
| Product architecture | exactly `arm64` | Confirmed by post-signing `lipo` inspection |

The observed values come from the immutable successful product-workflow log. A later
toolchain change requires updating both the pin and this record; do not infer
build numbers from marketing versions.

## Reproducible Commands

| Purpose | Command |
|---|---|
| Portable repository checks | `./scripts/check-repository.sh` |
| Automated unit and UI checks | `./scripts/test.sh` |
| Release-compatible locked shell | `./scripts/build-local.sh Release` |
| Direct process-probe comparison | `./scripts/build-local.sh DirectProbe` |
| Sandboxed process probe | `./scripts/build-local.sh SandboxProbe` |
| Launch and panel metrics | `./scripts/measure-workstream-1.sh` |
| Build, test, sign, and inspect lane | `./scripts/ci.sh` |

The hosted job runs `./scripts/ci.sh` and then
`./scripts/measure-workstream-1.sh`; `ci.sh` alone does not include the
performance lane. Product commands require native Apple Silicon and Xcode 26.3.
The current Linux host cannot substitute for them.

An earlier revision recorded that `xcresulttool` returned an empty metrics array
and attributed it to Xcode 26.3. That attribution was wrong for the Quick Search
fixture: it measured a signpost interval whose `.begin` is emitted by
`ApplicationCoordinator.showQuickSearch()`, which the fixture bypassed, so every
iteration emitted an unmatched `.end` and no sample could exist. With the
fixture driving the real presentation path, workflow `30696406614` exports the
interval. `XCTApplicationLaunchMetric` still exports nothing from the hosted run
and that remains unexplained; re-check it on the named Mac.

The runner also retains no `.xcresult`, because the workflow uploads no
artifact. Until the named-hardware measurements exist this lane is trend and
crash/hang detection only, not the p95 evidence required below, and
`measure-workstream-1.sh` prints an explicit warning when the array is empty so
an empty result cannot be mistaken for a pass.

## Entitlement Allowlist

For each configuration the scripts compare the signed entitlement keys against a
reviewed allowlist written into `scripts/verify-product.sh`, and separately
require the entitlement source file to match that same allowlist, so editing the
file alone cannot widen the signed capability set. They also reject
`get-task-allow`, the code-signing debugger entitlement, `temporary-exception`
file exceptions, JIT, unsigned-memory, library-validation bypass, dyld, and
Apple Events capabilities.

| Build | Entitlement | Reason |
|---|---|---|
| Release and direct probe | `com.apple.security.application-groups` | Reserve `group.ch.lkmc.VaultSquire` before secret-bearing storage, as accepted by ADR 0001 |
| Sandbox probe | `com.apple.security.app-sandbox` | Test inherited sandbox behavior rather than claim it works |
| Sandbox probe | `com.apple.security.application-groups` | Keep the accepted product container identity unchanged during comparison |
| Sandbox probe | `com.apple.security.files.user-selected.read-only` | Obtain read-only security-scoped access from explicit executable/session-directory selection |
| Sandbox probe | `com.apple.security.network.client` | Permit the candidate `info` status check to exercise its normal client path. `info` is not yet pinned in `PROTON_PASS_RESEARCH.md`; pin the exact command, revision, and output schema before the manual run, and drop this entitlement if the pinned status command turns out not to need the network |

Hardened Runtime is a code-signing flag, not an entitlement. Local and hosted
artifacts are ad-hoc signed only; Developer ID identity, notarization, stapling,
and clean-install release evidence remain later gates.

## Process Feasibility Procedure

Use only a disposable Proton test account and an official CLI installed and
authenticated independently in the user's own terminal. Never enter credentials
into VaultSquire, attach CLI output, or record full executable/session paths.

### What this harness does and does not answer

The harness answers whether a user-selected executable can be launched at all,
and whether that differs between the direct and sandboxed signatures. It does
**not** answer the session and keyring legs of the Workstream 1 exit criterion.
The selected session directory is used only to take a read-only security-scoped
extension; it is never passed to the child, because the environment channel is
prohibited for session material and no session-path argument is pinned in
`PROTON_PASS_RESEARCH.md`. With no `HOME` in the fixed environment the CLI falls
back to the passwd-database home, which App Sandbox redirects to the container,
so the selected directory is never read either way. Pinning a documented
absolute session-path argument is the prerequisite for closing that leg; until
then, do not record a session or keyring result from this harness.

1. Run `./scripts/build-local.sh DirectProbe`, launch the resulting app, open
   Settings, and select the executable and existing session directory.
2. Run the startup and status probes. Record only pass/fail, exit category,
   macOS version, architecture, distribution mode, and exact separately verified
   CLI version/build identity.
3. Repeat with `./scripts/build-local.sh SandboxProbe` and the same resources.
   The two builds are written to separate product trees so the direct artifact
   cannot be overwritten by the sandboxed one.
4. Inspect unified logs and generated artifacts for synthetic canaries and raw
   output. The probe must retain neither stream and must not add `HOME`, `XDG_*`,
   credentials, tokens, or session paths to the child environment.
5. If sandbox execution or launch fails, record the failure honestly and select
   the direct Hardened Runtime route through the ADR process. Do not add a
   temporary-exception entitlement or privileged helper.

The probe never starts `login`; official CLI/browser authentication remains
outside VaultSquire.

## Exit Evidence

| Gate | Result |
|---|---|
| Clean Release `arm64` build and ad-hoc signed artifact | Passed in workflow `30696406614`. The run prints a SHA-256 for each configuration's archive; `ditto` archives are not byte-reproducible, so a digest identifies that run's artifact and cannot be re-derived from a later build |
| Release entitlement and linked-image inspection | Passed in workflow `30696406614`; direct and sandbox probe allowlists also passed |
| Unit, UI, cancellation, timeout, and output-bound tests | Passed in workflow `30696406614`. The lane runs 19 unit and 3 UI test methods; the two performance fixtures are skipped there and run in the performance lane |
| Cold launch p95 at or below 750 ms on named baseline hardware | Pending named-Mac measurement. The fixture runs, but `XCTApplicationLaunchMetric` still exports no machine-readable metric from the hosted run and that remains unexplained |
| Warm Quick Search p95 at or below 100 ms on named baseline hardware | Pending named-Mac measurement. The fixture now produces samples: workflow `30696406614` recorded `[5.2, 5.9, 4.8, 7.1, 3.6] ms` on the hosted runner. That is a hosted trend figure with five samples, not a p95 on named baseline hardware |
| Keyboard focus and Escape dismissal | Automated UI test passed; manual confirmation required |
| VoiceOver and Full Keyboard Access | Pending interactive test |
| Multiple Spaces and full-screen auxiliary presentation | Pending interactive test |
| Direct versus sandbox executable launch behavior | Pending disposable-account test |
| Direct versus sandbox session and keyring behavior | Not implemented. Blocked on pinning a documented absolute session-path argument; see Process Feasibility Procedure |
| Security-scoped bookmark round trip across launches | Not implemented. The harness exercises only live same-launch selections |
| Executable code signature and notarization status recorded at approval | Not implemented. Symlinks are resolved before approval; signature inspection is deferred |
| Descendant holding the probe pipes open | Bounded and reported as `outputRemainedOpen`; covered by an automated fixture |
| Generated 16/32/64 px icon review | Blocked; no derived icon is included |

Workstream 1 merged into `main` as PR #5 on 2026-08-01 with the rows above still
outstanding. That was a deliberate owner decision, recorded in
[ADR 0006](docs/adr/0006-workstream-1-merge-with-outstanding-evidence.md), and
not a waiver: every outstanding row is still owed.

The gate moved rather than disappeared. No release, private preview, or
distributed artifact may be produced while any row above is outstanding, and the
Phase 0 gate over Workstreams 0-3 cannot be certified as passed while any of them
is outstanding.

Certifying a phase and working inside it are separate things. Workstream 2 sits
inside Phase 0, so the uncertified phase gate does not stop it starting or
merging; what the outstanding rows prevent is Phase 0 being declared complete.
Work inside the phase proceeds where it does not consume outstanding evidence,
which is why what each row blocks is stated here rather than argued later.

Workstream 2 consumes none of it: it models domain, session, and provider
contracts against a fake provider facade and depends on no hardware measurement,
accessibility result, or sandbox outcome from this workstream. The three rows
recorded as not implemented block Workstream 10, the Proton CLI provider. The
rest block the Phase 0 certification and any release.

Presence in `main` is not evidence that a criterion passed; a row is marked
passed only when the evidence exists. Every subsequent workstream record restates
the rows still outstanding here until they are discharged.
