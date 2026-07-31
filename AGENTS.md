# VaultSquire agent and contributor notes

VaultSquire is a planned native macOS password-manager client for self-hosted
Vaultwarden and, later, Proton Pass through the official user-installed CLI.
This history-isolated repository currently contains research, governance, and
design only. There is no application implementation, build command, test suite,
or release process.

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

`IMPLEMENTATION_CONTEXT.md` records the accepted history-isolation attestation.
Application code, package manifests, Xcode projects, project generators, build
scripts, product CI, and release workflows remain blocked until Workstream 0's
governance and evidence exit criteria are recorded and reviewed. Superseded
planning history is never an approved coding input.

Do not inspect or use earlier Keyguard-derived commits as implementation context.
Do not include a Keyguard checkout, source-derived notes, or source-level
comparisons in prompts, fixtures, reviews, or build environments.

## Source hygiene

- Do not copy, translate, port, adapt, or mechanically reproduce Keyguard code,
  architecture, tests, strings, assets, database designs, or distinctive UI.
- Bitwarden, Vaultwarden, and Proton sources are pinned protocol evidence, not
  implementation source. Do not copy their expression into product code.
- Proton integration is through the official user-installed CLI only. Do not
  implement Proton's private API, cryptography, or session model.
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
- CLI secrets never travel in argv, environment variables, logs, or plaintext files.
- Writes remain disabled until their provider-specific conflict and secret-input
  contracts have positive, negative, cancellation, ambiguity, and leakage tests.

## Current verification

Only documentation and repository hygiene can be verified today:

- links and Markdown structure;
- JSON/YAML syntax;
- whitespace;
- presence of governance files;
- absence of tracked IDE state and secret material.

Do not invent `swift test`, `xcodebuild`, signing, notarization, or release
commands before a real project exists. Each future CI job must land with the
reproducible local command it runs.

## Repository automation

- `repository-hygiene.yml` validates governance and rejects tracked local/secret files.
- `zai-code-review.yml` is explicit opt-in through the `glm-review` label. Add
  that label only when the PR diff may be sent to Z.ai. Never label embargoed
  security, licensing, provenance, or contamination work for external review.
- Dependabot currently covers GitHub Actions only. Add Swift coverage after a
  real dependency manifest exists.
- `.claude/settings.json` enables the shared Claude cloud MCP tools but does not
  supersede the clean-room and secret-handling rules above.

Preserve `media-sources/icon.png` as the canonical source artwork. Generated
assets must wait for the implementation context and a recorded ownership review.
