# Contributing

VaultSquire accepts work only in the numbered sequence recorded by
[`DELIVERY.md`](DELIVERY.md). The history-isolation attestation and Workstream 0
governance are recorded; application changes begin with Workstream 1 and cannot
merge until that workstream's macOS exit criteria pass.

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

GLM review is optional and external. Add the `glm-review` label only when the
entire diff is suitable for submission to Z.ai. Human security and provenance
review remains mandatory regardless of automated feedback.
