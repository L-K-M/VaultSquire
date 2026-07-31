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
- An actor-isolated process probe that uses an absolute executable URL, no shell,
  a fixed environment, null stdin, bounded stdout/stderr byte counting, timeout,
  and cancellation termination.
- A sandbox-only Settings tab for selecting an executable and optional existing
  CLI session directory through `NSOpenPanel`. It can run only startup or the
  documented non-interactive `info` command and never displays or retains raw
  output.
- Unit, UI, launch, and signpost performance fixtures.
- Reproducible Apple Silicon build, ad-hoc Hardened Runtime signing, entitlement,
  linked-image, and architecture inspection scripts.

No third-party application package is adopted. The global shortcut remains an
in-app menu shortcut until the candidate comparison and manual interaction gate
pass. Generated app icons remain blocked by `ICON_PROVENANCE.md`.

## Toolchain Pin

| Property | Required value | Observed value |
|---|---|---|
| Runner | GitHub-hosted Apple Silicon `macos-15` | macOS `15.7.7`, `arm64` in workflow run `30667545112` |
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
| Complete hosted-CI lane | `./scripts/ci.sh` |

Product commands require native Apple Silicon and Xcode 26.3. The current Linux
host cannot substitute for them.

## Entitlement Allowlist

The scripts reject any signed entitlement key outside the selected file and
explicitly reject debug, JIT, unsigned-memory, library-validation bypass, dyld,
and Apple Events capabilities.

| Build | Entitlement | Reason |
|---|---|---|
| Release and direct probe | `com.apple.security.application-groups` | Reserve `group.ch.lkmc.VaultSquire` before secret-bearing storage, as accepted by ADR 0001 |
| Sandbox probe | `com.apple.security.app-sandbox` | Test inherited sandbox behavior rather than claim it works |
| Sandbox probe | `com.apple.security.application-groups` | Keep the accepted product container identity unchanged during comparison |
| Sandbox probe | `com.apple.security.files.user-selected.read-only` | Obtain read-only security-scoped access from explicit executable/session-directory selection |
| Sandbox probe | `com.apple.security.network.client` | Permit the selected CLI's documented `info` status check to exercise its normal client path |

Hardened Runtime is a code-signing flag, not an entitlement. Local and hosted
artifacts are ad-hoc signed only; Developer ID identity, notarization, stapling,
and clean-install release evidence remain later gates.

## Process Feasibility Procedure

Use only a disposable Proton test account and an official CLI installed and
authenticated independently in the user's own terminal. Never enter credentials
into VaultSquire, attach CLI output, or record full executable/session paths.

1. Run `./scripts/build-local.sh DirectProbe`, launch the resulting app, open
   Settings, and select the executable and existing session directory.
2. Run startup and session/keyring probes. Record only pass/fail, exit category,
   macOS version, architecture, distribution mode, and exact separately verified
   CLI version/build identity.
3. Repeat with `./scripts/build-local.sh SandboxProbe` and the same resources.
4. Inspect unified logs and generated artifacts for synthetic canaries and raw
   output. The probe must retain neither stream and must not add `HOME`, `XDG_*`,
   credentials, tokens, or session paths to the child environment.
5. If sandbox execution, session discovery, or keyring access fails, record the
   failure honestly and select the direct Hardened Runtime route through the ADR
   process. Do not add a temporary-exception entitlement or privileged helper.

The probe never starts `login`; official CLI/browser authentication remains
outside VaultSquire.

## Exit Evidence

| Gate | Result |
|---|---|
| Clean Release `arm64` build and ad-hoc signed artifact | Passed in workflow `30667545112`; archive SHA-256 `5ddfa7ef38e50ee9dc10d04cf859aea71193b1560940b0d091c6fd0e6fe29a55` |
| Release entitlement and linked-image inspection | Passed in workflow `30667545112`; direct and sandbox probe allowlists also passed |
| Unit, UI, cancellation, timeout, and output-bound tests | Passed 13 unit and 3 UI tests in workflow `30667545112` |
| Cold launch p95 at or below 750 ms on named baseline hardware | Pending named-Mac measurement |
| Warm Quick Search p95 at or below 100 ms on named baseline hardware | Pending named-Mac measurement |
| Keyboard focus and Escape dismissal | Automated UI test passed; manual confirmation required |
| VoiceOver and Full Keyboard Access | Pending interactive test |
| Multiple Spaces and full-screen auxiliary presentation | Pending interactive test |
| Direct versus sandbox executable/session/keyring behavior | Pending disposable-account test |
| Generated 16/32/64 px icon review | Blocked; no derived icon is included |

The Workstream 1 pull request must not merge, and Workstream 2 must not begin,
while any controlling exit criterion remains pending.
