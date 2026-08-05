# Contributing

VaultSquire accepts work only in the numbered sequence recorded by
[`DELIVERY.md`](DELIVERY.md). The history-isolation attestation, Workstream 0
governance, and the Workstream 1 native shell are recorded. Workstream 1 merged
with several macOS exit criteria still outstanding, by the decision in
[ADR 0006](docs/adr/0006-workstream-1-merge-with-outstanding-evidence.md); those
criteria are still owed and now gate any release rather than the merge. Merging
into `main` is not evidence that a workstream's exit criteria passed.

Contributions are released under the
[Apache License 2.0](LICENSE).

## Before contributing

Read [README.md](README.md), the controlling documents it lists, and
[AGENTS.md](AGENTS.md). A proposal must identify:

- the controlling document and section it changes;
- whether it affects Vaultwarden, Proton CLI, shared platform behavior, or governance;
- primary or immutable evidence for external claims;
- security, privacy, compatibility, licensing, and provenance consequences;
- unsupported or deferred behavior that remains after the change.

## Clean-room requirements

- Do not use Keyguard source or source-derived implementation details.
- Do not copy or mechanically translate Bitwarden, Vaultwarden, or Proton code.
- Do not paste upstream private implementation into issues, pull requests, or prompts.
- Use original wording and design derived from approved requirements and public evidence.
- Explain the provenance of every nontrivial artifact and dependency proposal.

## Test data and reports

Use synthetic examples only. Never provide production vault records, real
credentials, tokens, TOTP seeds, private keys, CLI output, databases, logs, or
unsanitized URLs. Security and contamination concerns must be reported privately.

## Verification

Verify documentation links, formatting, cited revisions, internal consistency,
and repository hygiene with `./scripts/check-repository.sh`, which runs on any
host. On a native Apple Silicon Mac with the pinned Xcode, also run the build,
test, signing, and inspection commands recorded in
[`WORKSTREAM_1.md`](WORKSTREAM_1.md). Do not add placeholder product CI or
fictional commands, and do not claim a macOS, accessibility, hardware
performance, signing, notarization, or process-sandbox result that was not
actually produced on such a Mac.

Use `./scripts/build.sh` as the local build entry point and
`./scripts/build.sh --check` to inspect its contract on any host. Release
automation is security-boundary code: do not enable
`.github/release-eligibility.env`, add the matching approval marker, create a
release tag, or configure signing material until every controlling gate is
recorded and the change has two focused human reviewers. See [`CICD.md`](CICD.md).

GLM review is optional and external. Add the `glm-review` label only when the
entire diff is suitable for submission to Z.ai. Human security and provenance
review remains mandatory regardless of automated feedback.
