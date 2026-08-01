# Workstream 1 Native Shell And Performance Record

- Status: implementation in progress; exit evidence incomplete
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
| Runner | GitHub-hosted Apple Silicon `macos-15` | macOS `15.7.7`, `arm64` in workflow run `30668464126` |
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

The hosted performance fixtures execute their measured iterations, but
`xcresulttool` returned an empty machine-readable metrics array for the hosted
run and the runner retains no `.xcresult` afterwards, because the workflow
uploads no artifact. Two separate causes were in play and only one is fixed
here: the warm Quick Search fixture used to bypass the code that opens the
signpost interval, so it could never have produced a sample, and that is
corrected. Why the launch metric also exported nothing is still unexplained and
must be re-checked on the named Mac. Until then this lane detects crashes and
hangs only; it is not the named-hardware p95 evidence required below, and
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
| Clean Release `arm64` build and ad-hoc signed artifact | Passed in workflow `30668464126`; archive SHA-256 `85fae3abc1f83baab259f6c43b6efc6f2aca4b758c298ab203d14174b8e06734` |
| Release entitlement and linked-image inspection | Passed in workflow `30668464126`; direct and sandbox probe allowlists also passed |
| Unit, UI, cancellation, timeout, and output-bound tests | Passed 14 unit and 3 UI tests in workflow `30668464126` |
| Cold launch p95 at or below 750 ms on named baseline hardware | Pending named-Mac measurement; the hosted lane exports no metrics |
| Warm Quick Search p95 at or below 100 ms on named baseline hardware | Pending named-Mac measurement. The fixture previously measured a signpost interval it never opened and could not have produced a sample; that is fixed, but no sample has been observed yet |
| Keyboard focus and Escape dismissal | Automated UI test passed; manual confirmation required |
| VoiceOver and Full Keyboard Access | Pending interactive test |
| Multiple Spaces and full-screen auxiliary presentation | Pending interactive test |
| Direct versus sandbox executable launch behavior | Pending disposable-account test |
| Direct versus sandbox session and keyring behavior | Not implemented. Blocked on pinning a documented absolute session-path argument; see Process Feasibility Procedure |
| Security-scoped bookmark round trip across launches | Not implemented. The harness exercises only live same-launch selections |
| Executable code signature and notarization status recorded at approval | Not implemented. Symlinks are resolved before approval; signature inspection is deferred |
| Descendant holding the probe pipes open | Bounded and reported as `outputRemainedOpen`; covered by an automated fixture |
| Generated 16/32/64 px icon review | Blocked; no derived icon is included |

The Workstream 1 pull request must not merge, and Workstream 2 must not begin,
while any controlling exit criterion remains pending.
